#!/usr/bin/env bash
# The gitops-pr target on a pull request: one open pull request per preview label.
#
# A label-driven preview controller deploys the open pull request that carries a label to that
# label's environment: Flux Operator's ResourceSetInputProvider, type GitHubPullRequest, with
# `filter.labels: [<label>]` and `filter.limit: 1`. When two carry the label it takes the newest
# and says nothing, so a second pull request can take an environment from the first without
# either author knowing. Here the first to take a label keeps it, and a later one loses the
# label again and is told which pull request holds it.
#
# Nothing is deployed, as on any gitops-pr pull request run: the controller deploys, and this
# only takes labels off and writes comments.
#
#   labeled     Settle the label (below): this pull request holds it, or loses it.
#   unlabeled   If this pull request held the label, its comment says it was released. Then
#               settle the label.
#   closed      The same for every preview label it carries, and the labels come off: a
#               closed pull request is not deployed, and reopening it must not take an
#               environment back without a word.
#
# SETTLING A LABEL
#
# Every open pull request carrying it is a claim. The holder is the one whose label went on
# first, by its latest `labeled` event, the event id breaking a tie inside one second. Every
# other claim loses the label and gets a comment naming the holder. A run settles the whole
# label, not only its own pull request, so two claims made at once end the same way in both
# runs, and a run that never happened (one a concurrency group cancelled) leaves nothing
# unsettled for the next one.
#
# WHO HELD IT
#
# Taking a refused label off with an App token fires `unlabeled` again, and that run must not
# tell a pull request that never held the environment that it released it. The sticky comment
# records the state, and only a pull request whose comment says it holds the label releases it.
#
# Env: EVENT_PATH, GITHUB_API_URL, GITHUB_REPOSITORY, AUTH_TOKEN, LABELS, URLS, DRY_RUN
# Outputs: result (claimed | refused | released | ignored)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

EVENT_PATH="${EVENT_PATH:-${GITHUB_EVENT_PATH:-}}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
LABELS="${LABELS:-}"
URLS="${URLS:-}"
DRY_RUN="${DRY_RUN:-false}"

# notify-pr.sh reads these.
export GITHUB_API_URL GITHUB_REPOSITORY AUTH_TOKEN

tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN "auth-token, a token that may write pull requests"
[[ -n "$EVENT_PATH" && -f "$EVENT_PATH" ]] || tremvok::fail "gitops-preview-labels: the event payload is missing"

# One label per line, because a label name may hold spaces.
labels=()
while IFS= read -r l; do
  l="$(printf '%s' "$l" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "$l" ]] || labels+=("$l")
done <<<"$LABELS"
[[ "${#labels[@]}" -gt 0 ]] || tremvok::fail "gitops-preview-labels names no label"

# Two lines rather than ${URLS:-{}}; validate-inputs.sh says why.
[[ -n "$URLS" ]] || URLS='{}'
jq -e 'type == "object" and all(.[]; type == "string")' <<<"$URLS" >/dev/null 2>&1 \
  || tremvok::fail "gitops-preview-urls must be a JSON object from label to URL, got: ${URLS}"
stray="$(printf '%s\n' "${labels[@]}" | jq -Rrn --argjson u "$URLS" '[inputs] as $l | $u | keys - $l | join(", ")')"
[[ -z "$stray" ]] || tremvok::fail "gitops-preview-urls: ${stray} is not one of gitops-preview-labels"

action="$(jq -r '.action // empty' "$EVENT_PATH")"
number="$(jq -r '.pull_request.number // empty' "$EVENT_PATH")"
event_label="$(jq -r '.label.name // empty' "$EVENT_PATH")"
[[ -n "$number" ]] \
  || tremvok::fail "gitops-preview-labels acts on a pull_request event (labeled, unlabeled, closed); this one carries no pull request"

API="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# http METHOD URL: the status code on stdout, the body in $WORK/response.
http() {
  local code
  code="$(curl --silent --show-error --location --retry 2 --max-time 20 \
    --output "${WORK}/response" --write-out '%{http_code}' \
    --header "authorization: Bearer ${AUTH_TOKEN}" \
    --header 'accept: application/vnd.github+json' \
    --header 'x-github-api-version: 2022-11-28' \
    --request "$1" "$2")" || code=000
  printf '%s' "$code"
}

reason() { jq -r '.message // empty' "${WORK}/response" 2>/dev/null | head -c 300; }

# get URL CONTEXT: a read that has to succeed.
get() {
  local code
  code="$(http GET "$1")"
  [[ "$code" == 200 ]] || tremvok::fail "gitops-preview-labels: ${2} failed (HTTP ${code}): $(reason)"
}

# Is $1 one of gitops-preview-labels?
is_preview() {
  local l
  for l in "${labels[@]}"; do
    if [[ "$l" == "$1" ]]; then return 0; fi
  done
  return 1
}

key() { printf 'gitops-preview-%s' "$(tremvok::slug "$1")"; }

# say NUMBER LABEL STATE TEXT: the pull request's sticky comment for LABEL, recording STATE.
# Failure-isolated, as every comment is: the label is the claim, the comment only says so.
say() {
  if tremvok::is_true "$DRY_RUN"; then
    tremvok::log "dry run: would tell #${1}: ${4}"
    return 0
  fi
  PR_NUMBER="$1" COMMENT_KEY="$(key "$2")" BODY="<!-- tremvok-claim:${3} -->"$'\n'"${4}" \
    bash "${here}/notify-pr.sh" </dev/null \
    || tremvok::warn "could not comment on #${1}; the claim stands as it is"
}

# Does pull request $1's comment for label $2 say it holds the label? The comment read is the
# one notify-pr.sh edits: the last carrying the marker, on the first page that has one.
holds() {
  local marker page=1 body
  marker="<!-- tremvok:$(key "$2") -->"
  while ((page <= 10)); do
    if [[ "$(http GET "${API}/issues/${1}/comments?per_page=100&page=${page}")" != 200 ]]; then
      tremvok::warn "could not read the comments on #${1}, so it is not known to have held ${2}"
      return 1
    fi
    body="$(jq -r --arg m "$marker" '[.[] | .body // "" | select(contains($m))] | last // empty' "${WORK}/response")"
    if [[ -n "$body" ]]; then
      if [[ "$body" == *"<!-- tremvok-claim:held -->"* ]]; then return 0; fi
      return 1
    fi
    if [[ "$(jq 'length' "${WORK}/response")" -ne 100 ]]; then return 1; fi
    page=$((page + 1))
  done
  return 1
}

# unlabel NUMBER LABEL: take the label off. Not failure-isolated: a refused claim that keeps
# its label is one the controller can still deploy.
unlabel() {
  if tremvok::is_true "$DRY_RUN"; then
    tremvok::log "dry run: would take ${2} off #${1}"
    return 0
  fi
  local code
  code="$(http DELETE "${API}/issues/${1}/labels/$(jq -rn --arg v "$2" '$v | @uri')")"
  case "$code" in
    200|404) tremvok::log "took ${2} off #${1}" ;;
    *) tremvok::fail "gitops-preview-labels: could not take ${2} off #${1} (HTTP ${code}): $(reason)" ;;
  esac
}

# The open pull requests carrying label $1, one number a line, into $WORK/claims. The pulls API
# rather than the issues one, so the token needs nothing beyond pull requests.
# shortcut: the first 1,000 open pull requests; page further if a repository keeps more open.
claims() {
  local page=1
  : >"${WORK}/claims"
  while ((page <= 10)); do
    get "${API}/pulls?state=open&per_page=100&page=${page}" "listing the open pull requests"
    jq -r --arg l "$1" '.[] | select(any(.labels[]?; .name == $l)) | .number' "${WORK}/response" >>"${WORK}/claims"
    if [[ "$(jq 'length' "${WORK}/response")" -ne 100 ]]; then return 0; fi
    page=$((page + 1))
  done
}

# Append "<time> <event id> <number>" for when label $2 last went on pull request $1 to
# $WORK/order, which then sorts in the order the label events happened. A claim with no event
# to show for it (the label renamed since, or past the pages read) sorts last: a claim that
# cannot show when it began does not outrank one that can.
rank() {
  local page=1 last="" found
  while ((page <= 10)); do
    get "${API}/issues/${1}/events?per_page=100&page=${page}" "reading the events of #${1}"
    found="$(jq -r --arg l "$2" '[.[] | select(.event == "labeled" and .label.name == $l) | "\(.created_at) \(.id)"] | last // empty' "${WORK}/response")"
    if [[ -n "$found" ]]; then last="$found"; fi
    if [[ "$(jq 'length' "${WORK}/response")" -ne 100 ]]; then break; fi
    page=$((page + 1))
  done
  if [[ -z "$last" ]]; then
    tremvok::warn "#${1} carries ${2}, but none of its events shows it going on; it ranks last"
    last="9999 0"
  fi
  printf '%s %s\n' "$last" "$1" >>"${WORK}/order"
}

# settle LABEL: the first claim holds the label, every other loses it. Sets $holder, empty when
# no open pull request carries the label.
# shellcheck disable=SC2016 # the backticks are Markdown code spans, not command substitution.
settle() {
  local l="$1" n url text
  holder=""
  claims "$l"
  if [[ ! -s "${WORK}/claims" ]]; then
    tremvok::log "no open pull request carries ${l}"
    return 0
  fi
  if [[ "$(wc -l <"${WORK}/claims")" -gt 1 ]]; then
    : >"${WORK}/order"
    while IFS= read -r n; do rank "$n" "$l"; done <"${WORK}/claims"
    # awk reads all its input, so sort never meets a closed pipe under pipefail.
    holder="$(LC_ALL=C sort -k1,1 -k2,2n -k3,3n "${WORK}/order" | awk 'NR == 1 { print $3 }')"
  else
    holder="$(cat "${WORK}/claims")"
  fi

  url="$(jq -r --arg l "$l" '.[$l] // empty' <<<"$URLS")"
  text="$(printf 'This pull request holds `%s`.' "$l")"
  if [[ -n "$url" ]]; then text="$(printf 'This pull request holds `%s`: %s' "$l" "$url")"; fi
  say "$holder" "$l" held "${text}"$'\n\n'"Remove the label, or close the pull request, to release it."

  while IFS= read -r n; do
    [[ "$n" != "$holder" ]] || continue
    # The comment goes first: the `unlabeled` an App token's removal fires reads it.
    say "$n" "$l" refused "\`${l}\` is in use by #${holder}, so the label came off here. Remove it there first, then label this pull request again."
    unlabel "$n" "$l"
    tremvok::notice "#${n} claimed ${l}, which #${holder} holds"
  done <"${WORK}/claims"
}

# release LABEL: this pull request lets go of the label, if its comment says it held it.
release() {
  if holds "$number" "$1"; then
    say "$number" "$1" released "\`${1}\` was released: this pull request no longer holds it."
    result=released
    tremvok::notice "#${number} released ${1}"
  else
    tremvok::log "#${number} did not hold ${1}; nothing to release"
  fi
}

result=ignored
holder=""

case "$action" in
  labeled|unlabeled)
    if ! is_preview "$event_label"; then
      tremvok::log "'${event_label}' is not one of gitops-preview-labels; nothing to do"
    else
      if [[ "$action" == unlabeled ]]; then release "$event_label"; fi
      settle "$event_label"
      if [[ "$action" == labeled && "$holder" == "$number" ]]; then
        result=claimed
        tremvok::notice "#${number} holds ${event_label}"
      elif [[ "$action" == labeled ]] && grep -qx "$number" "${WORK}/claims"; then
        result=refused
      fi
    fi
    ;;
  closed)
    jq -r '.pull_request.labels[]?.name' "$EVENT_PATH" >"${WORK}/carried"
    while IFS= read -r l; do
      is_preview "$l" || continue
      release "$l"
      unlabel "$number" "$l"
      settle "$l"
    done <"${WORK}/carried"
    ;;
  *)
    tremvok::log "a '${action}' event changes no claim"
    ;;
esac

tremvok::set_output result "$result"
tremvok::log "gitops-preview-labels: #${number} ${result}"
