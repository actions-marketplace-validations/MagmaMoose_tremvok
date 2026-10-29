#!/usr/bin/env bash
# Open, refresh or retire the deploy pull request for one kustomize overlay.
#
# The gitops-pr target's one write. It moves `newTag` for the given images in one overlay's
# kustomization file, on a branch of its own, `<prefix>/<overlay>/<tag>`, and opens a pull
# request for it. Merging that pull request is the deployment: the overlay is what Flux or
# Argo CD applies, and Tremvok never touches the cluster.
#
# ONE OPEN DEPLOY PR PER OVERLAY
#
#   - a pull request for another tag is closed as superseded, and its branch deleted;
#   - a re-run for the same tag refreshes the open pull request's title and body;
#   - an overlay that already runs the tag gets no pull request, and open ones for an older
#     tag are closed, since merging them would roll it back;
#   - an overlay that runs something NEWER (a hotfix merged straight to it) is left alone,
#     and so is an open pull request for a newer tag: two promotions can race, and the older
#     one must not replace the newer.
#
# A NEW BRANCH PER TAG, NEVER A RESET
#
# GitHub marks a pull request as merged the moment its head points at a commit the base
# already contains. Resetting an open pull request's branch to the base, to commit the new
# tag on top, therefore closes it as merged with nothing in it, and the reviewer sees a merged
# deploy that deployed nothing. A new tag gets a new branch; the old pull request is closed.
#
# ONE LINE PER IMAGE
#
# Only the value on the entry's `newTag:` line changes, located with yq and rewritten with
# sed, so a trailing comment (a Flux `$imagepolicy` marker left from image automation) and the
# file's layout survive, and the diff is one line per image. `yq -i` would re-serialise the
# whole file. A flow-style entry is refused rather than half-edited.
#
# WHAT PROVES IT TOOK EFFECT
#
# The file is read back from the deploy branch after the commit, and every image must carry the
# tag it was meant to. What the cluster does after the merge is the caller's to assert, with
# `verify-url` on the run the merge starts.
#
# Commits go through the contents API, which is what makes an App's commits signed: a
# signed-commits rule on the base would refuse the pull request's commit otherwise.
#
# Env:
#   GITHUB_API_URL, GITHUB_REPOSITORY, AUTH_TOKEN  the API, and a token that may write
#                  contents and pull requests. An App token: a pull request opened with
#                  GITHUB_TOKEN starts no workflow, so its required checks never report.
#   OVERLAY        overlay directory, relative to the repository root
#   BASE           branch the overlay is read from and the pull request targets
#   IMAGES         JSON object, image repository -> tag to set
#   TAG            the tag the pull request is named after (branch and title)
#   BRANCH_PREFIX  default "deploy"
#   NEXT_OVERLAY   name of the overlay whose pull request opens when this one merges
#   SOURCE_NOTE    one markdown line saying where the tag comes from
#   DRY_RUN        true: read and report, write nothing
# Outputs: url, number, result (created | refreshed | unchanged | skipped | planned)
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
OVERLAY="${OVERLAY:-}"
BASE="${BASE:-}"
IMAGES="${IMAGES:-}"
TAG="${TAG:-}"
BRANCH_PREFIX="${BRANCH_PREFIX:-deploy}"
NEXT_OVERLAY="${NEXT_OVERLAY:-}"
SOURCE_NOTE="${SOURCE_NOTE:-}"
DRY_RUN="${DRY_RUN:-false}"

tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN "auth-token, a token that may write contents and pull requests"
tremvok::require OVERLAY
tremvok::require BASE "gitops-base"
tremvok::require IMAGES "gitops-images"
tremvok::require TAG "gitops-tag"

PREFIX="${BRANCH_PREFIX%/}"
OVERLAY="${OVERLAY#./}"
OVERLAY="${OVERLAY%/}"
NAME="${OVERLAY##*/}"
BRANCH="${PREFIX}/${NAME}/${TAG}"
TITLE="chore(deploy): ${TAG} to ${NAME}"
API="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}"

# The Docker tag grammar. It also keeps every tag safe inside the sed replacement below,
# which it is spliced into.
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
[[ "$TAG" =~ $TAG_RE ]] || tremvok::fail "gitops-pr: '${TAG}' is not a valid image tag"
jq -e 'type == "object" and length > 0 and all(.[]; type == "string")' <<<"$IMAGES" >/dev/null 2>&1 \
  || tremvok::fail "gitops-pr: IMAGES must be a non-empty JSON object from image repository to tag, got: ${IMAGES}"
while IFS= read -r t; do
  [[ "$t" =~ $TAG_RE ]] || tremvok::fail "gitops-pr: '${t}' is not a valid image tag"
done < <(jq -r '.[]' <<<"$IMAGES")

command -v yq >/dev/null 2>&1 \
  || tremvok::fail "gitops-pr needs yq (mikefarah/yq v4) on the runner to read kustomization files; it is on GitHub's hosted runners, and a self-hosted one needs it installed."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# http METHOD URL [BODY-FILE]: the status code on stdout, the body in $WORK/response.
# The status is the answer, not curl's exit code: a 404 here is "no such branch" or "no such
# file", which this script acts on, and it must never be confused with an outage.
http() {
  local method="$1" url="$2" data="${3:-}" code
  local args=(--silent --show-error --location --retry 2 --max-time 30
    --output "${WORK}/response" --write-out '%{http_code}'
    --header "authorization: Bearer ${AUTH_TOKEN}"
    --header 'accept: application/vnd.github+json'
    --header 'x-github-api-version: 2022-11-28'
    --request "$method")
  if [[ -n "$data" ]]; then
    args+=(--header 'content-type: application/json' --data-binary "@${data}")
  fi
  code="$(curl "${args[@]}" "$url")" || code=000
  printf '%s' "$code"
}

# must METHOD URL [BODY-FILE] CONTEXT: the call has to succeed; its body lands in $WORK/response.
must() {
  local method="$1" url="$2" data="${3:-}" context="$4" code
  code="$(http "$method" "$url" "$data")"
  case "$code" in
    2??) ;;
    *) tremvok::fail "gitops-pr: ${context} failed (HTTP ${code}): $(jq -r '.message // empty' "${WORK}/response" 2>/dev/null | head -c 300)" ;;
  esac
}

# SemVer precedence, so a release candidate's own stable release is newer than it, not older.
version_gt() { tremvok::version_gt "$1" "$2"; }

# yq prints CRLF on Windows runners.
yqv() { yq "$@" | tr -d '\r'; }

SEL='(.images // [])[] | select((.newName // .name) == strenv(GITOPS_IMAGE))'

# set_tag FILE IMAGE TAG: point the images[] entry for IMAGE at TAG. 0 on success (already at
# TAG included), 3 when the file has no entry for IMAGE, and a failure on an entry it will
# not move.
set_tag() {
  local file="$1" image="$2" tag="$3" count line
  export GITOPS_IMAGE="$image"
  count="$(yqv "[${SEL}] | length" "$file")"
  [[ "$count" != "0" ]] || return 3
  [[ "$count" == "1" ]] || tremvok::fail "gitops-pr: ${FILE} has ${count} images[] entries for ${image}; expected one"
  [[ "$(yqv "${SEL} | has(\"digest\")" "$file")" != "true" ]] \
    || tremvok::fail "gitops-pr: ${FILE} pins ${image} by digest, which outranks newTag; remove the digest to deploy by tag"
  [[ "$(yqv "${SEL} | has(\"newTag\")" "$file")" == "true" ]] \
    || tremvok::fail "gitops-pr: the images[] entry for ${image} in ${FILE} has no newTag to move"
  line="$(yqv "${SEL} | .newTag | line" "$file")"
  sed -E "${line}s/^([[:space:]]*(-[[:space:]]+)?newTag:[[:space:]]*)([\"']?)[A-Za-z0-9_][A-Za-z0-9._-]*([\"']?)/\\1\\3${tag}\\4/" \
    "$file" >"${file}.new"
  mv "${file}.new" "$file"
  [[ "$(yqv "${SEL} | .newTag" "$file")" == "$tag" ]] \
    || tremvok::fail "gitops-pr: could not rewrite newTag for ${image} on line ${line} of ${FILE}; only a block-style 'newTag: <tag>' line is supported"
}

# ── The overlay at the tip of the base branch ──────────────────────────────────────────
must GET "${API}/git/ref/heads/${BASE}" "" "reading branch ${BASE}"
BASE_SHA="$(jq -r '.object.sha' "${WORK}/response")"

FILE=""
for f in kustomization.yaml kustomization.yml Kustomization; do
  code="$(http GET "${API}/contents/${OVERLAY}/${f}?ref=${BASE_SHA}")"
  case "$code" in
    200) FILE="${OVERLAY}/${f}"; break ;;
    404) ;;
    *) tremvok::fail "gitops-pr: reading ${OVERLAY}/${f} failed (HTTP ${code})" ;;
  esac
done
[[ -n "$FILE" ]] || tremvok::fail "gitops-pr: no kustomization.yaml, kustomization.yml or Kustomization in ${OVERLAY} on ${BASE}"
BLOB_SHA="$(jq -r '.sha' "${WORK}/response")"
jq -r '.content' "${WORK}/response" | base64 --decode >"${WORK}/before"
cp "${WORK}/before" "${WORK}/after"

# ── Move the tags ──────────────────────────────────────────────────────────────────────
: >"${WORK}/changes.tsv"
matched=0
while IFS=$'\t' read -r image tag; do
  old="$(GITOPS_IMAGE="$image" yqv "${SEL} | .newTag" "${WORK}/after")"
  rc=0
  set_tag "${WORK}/after" "$image" "$tag" || rc=$?
  case "$rc" in
    0) matched=$((matched + 1))
       [[ "$old" == "$tag" ]] || printf '%s\t%s\t%s\n' "$image" "$old" "$tag" >>"${WORK}/changes.tsv" ;;
    3) tremvok::warn "gitops-pr: ${FILE} has no images[] entry for ${image}; it is left out of this deploy" ;;
    *) exit "$rc" ;;
  esac
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$IMAGES")

if [[ "$matched" -eq 0 ]]; then
  tremvok::fail "gitops-pr: ${FILE} has an images[] entry for none of: $(jq -r 'keys | join(", ")' <<<"$IMAGES"). Its entries: $(yqv '[(.images // [])[] | (.newName // .name)] | join(", ")' "${WORK}/before")"
fi

# ── Open deploy pull requests for this overlay ─────────────────────────────────────────
must GET "${API}/pulls?state=open&base=${BASE}&per_page=100" "" "listing open pull requests"
jq -c --arg p "${PREFIX}/${NAME}/" \
  '[.[] | select(.head.ref | startswith($p)) | {number, url: .html_url, head: .head.ref, tag: (.head.ref | ltrimstr($p))}]' \
  "${WORK}/response" >"${WORK}/open.json"

close_pr() { # number branch comment
  local number="$1" branch="$2" comment="$3"
  tremvok::log "closing #${number}: ${comment}"
  if tremvok::is_true "$DRY_RUN"; then return 0; fi
  jq -n --arg body "$comment" '{body: $body}' >"${WORK}/comment.json"
  http POST "${API}/issues/${number}/comments" "${WORK}/comment.json" >/dev/null
  printf '{"state":"closed"}' >"${WORK}/close.json"
  [[ "$(http PATCH "${API}/pulls/${number}" "${WORK}/close.json")" == 2?? ]] \
    || tremvok::warn "gitops-pr: could not close #${number}"
  http DELETE "${API}/git/refs/heads/${branch}" >/dev/null
}

if [[ ! -s "${WORK}/changes.tsv" ]]; then
  tremvok::notice "gitops-pr: ${OVERLAY} already runs ${TAG} on ${BASE}; no deploy PR needed"
  while IFS=$'\t' read -r number head tag; do
    if ! version_gt "$tag" "$TAG"; then
      close_pr "$number" "$head" "Closed by Tremvok: \`${OVERLAY}\` already runs \`${TAG}\` on \`${BASE}\`, so merging this would change nothing or roll it back."
    fi
  done < <(jq -r '.[] | "\(.number)\t\(.head)\t\(.tag)"' "${WORK}/open.json")
  tremvok::set_output result unchanged
  exit 0
fi

# A deploy only ever moves an overlay forward. One that runs something newer was changed by
# hand, and proposing the older tag would roll that back.
downgrades=""
while IFS=$'\t' read -r image old new; do
  if version_gt "$old" "$new"; then downgrades="${downgrades}${image} (${old}, not ${new}) "; fi
done <"${WORK}/changes.tsv"
if [[ -n "$downgrades" ]]; then
  tremvok::notice "gitops-pr: ${OVERLAY} on ${BASE} already runs a newer tag for ${downgrades}; not proposing ${TAG}"
  tremvok::set_output result skipped
  exit 0
fi

newer=""
while IFS=$'\t' read -r number tag; do
  if version_gt "$tag" "$TAG"; then newer="${newer}#${number} (${tag}) "; fi
done < <(jq -r --arg t "$TAG" '.[] | select(.tag != $t) | "\(.number)\t\(.tag)"' "${WORK}/open.json")
if [[ -n "$newer" ]]; then
  tremvok::notice "gitops-pr: an open deploy PR for ${NAME} already proposes a newer tag: ${newer}; not opening one for ${TAG}"
  tremvok::set_output result skipped
  exit 0
fi

# ── The body ───────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016 # the backticks are Markdown code spans, not command substitution.
{
  printf 'Deploys `%s` to **%s** by moving `%s`:\n\n' "$TAG" "$NAME" "$FILE"
  printf '| Image | Now | After merge |\n| --- | --- | --- |\n'
  while IFS=$'\t' read -r image old new; do
    printf '| `%s` | `%s` | `%s` |\n' "$image" "${old:-none}" "$new"
  done <"${WORK}/changes.tsv"
  printf '\n'
  if [[ -n "$SOURCE_NOTE" ]]; then printf '%s\n\n' "$SOURCE_NOTE"; fi
  printf 'Merging this is the deployment.'
  if [[ -n "$NEXT_OVERLAY" ]]; then
    printf ' When it merges, Tremvok opens the same change for **%s**.' "$NEXT_OVERLAY"
  fi
  printf '\n\n<sub>Opened by Tremvok. A newer tag for %s replaces this pull request, and its branch belongs to Tremvok: push changes to a branch of your own.</sub>\n' "$NAME"
} >"${WORK}/body.md"

if tremvok::is_true "$DRY_RUN"; then
  tremvok::notice "gitops-pr: dry run; would open '${TITLE}' from ${BRANCH} into ${BASE}"
  cat "${WORK}/body.md"
  tremvok::set_output result planned
  exit 0
fi

supersede_others() { # keep-number
  local keep="$1" number head
  while IFS=$'\t' read -r number head; do
    close_pr "$number" "$head" "Superseded by #${keep} (\`${TAG}\`)."
  done < <(jq -r --arg b "$BRANCH" '.[] | select(.head != $b) | "\(.number)\t\(.head)"' "${WORK}/open.json")
}

same="$(jq -r --arg b "$BRANCH" 'first(.[] | select(.head == $b) | .number) // empty' "${WORK}/open.json")"
if [[ -n "$same" ]]; then
  jq -n --arg title "$TITLE" --rawfile body "${WORK}/body.md" '{title: $title, body: $body}' >"${WORK}/edit.json"
  must PATCH "${API}/pulls/${same}" "${WORK}/edit.json" "refreshing #${same}"
  url="$(jq -r '.html_url' "${WORK}/response")"
  tremvok::log "refreshed #${same}: ${url}"
  supersede_others "$same"
  tremvok::set_output url "$url"
  tremvok::set_output number "$same"
  tremvok::set_output result refreshed
  exit 0
fi

# ── A branch of its own, at the base tip ───────────────────────────────────────────────
# A branch left over without an open pull request (an earlier run that failed after pushing
# it, or a pull request someone closed) is deleted and made again: with no open pull request
# on it, removing it cannot close anything.
if [[ "$(http GET "${API}/git/ref/heads/${BRANCH}")" == "200" ]]; then
  tremvok::log "deleting leftover branch ${BRANCH}"
  http DELETE "${API}/git/refs/heads/${BRANCH}" >/dev/null
fi
jq -n --arg ref "refs/heads/${BRANCH}" --arg sha "$BASE_SHA" '{ref: $ref, sha: $sha}' >"${WORK}/ref.json"
must POST "${API}/git/refs" "${WORK}/ref.json" "creating branch ${BRANCH}"

jq -n --arg message "$TITLE" --arg branch "$BRANCH" --arg sha "$BLOB_SHA" \
  --arg content "$(base64 <"${WORK}/after" | tr -d '\n')" \
  '{message: $message, content: $content, sha: $sha, branch: $branch}' >"${WORK}/put.json"
must PUT "${API}/contents/${FILE}" "${WORK}/put.json" "committing ${FILE} to ${BRANCH}"

# Read it back: the pull request must carry exactly the tags it says it deploys.
must GET "${API}/contents/${FILE}?ref=${BRANCH}" "" "reading ${FILE} back from ${BRANCH}"
jq -r '.content' "${WORK}/response" | base64 --decode >"${WORK}/committed"
while IFS=$'\t' read -r image _ new; do
  got="$(GITOPS_IMAGE="$image" yqv "${SEL} | .newTag" "${WORK}/committed")"
  [[ "$got" == "$new" ]] \
    || tremvok::fail "gitops-pr: ${BRANCH} has ${image} at '${got}', not '${new}'; the deploy PR was not opened"
done <"${WORK}/changes.tsv"

jq -n --arg title "$TITLE" --arg head "$BRANCH" --arg base "$BASE" --rawfile body "${WORK}/body.md" \
  '{title: $title, head: $head, base: $base, body: $body}' >"${WORK}/pr.json"
must POST "${API}/pulls" "${WORK}/pr.json" "opening the deploy PR for ${BRANCH}"
url="$(jq -r '.html_url' "${WORK}/response")"
number="$(jq -r '.number' "${WORK}/response")"
printf '{"labels":["deploy"]}' >"${WORK}/labels.json"
http POST "${API}/issues/${number}/labels" "${WORK}/labels.json" >/dev/null || true
tremvok::log "opened #${number}: ${url}"

supersede_others "$number"
tremvok::set_output url "$url"
tremvok::set_output number "$number"
tremvok::set_output result created
