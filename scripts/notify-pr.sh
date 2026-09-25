#!/usr/bin/env bash
# One sticky pull-request comment, edited in place.
#
# Three repositories in the fleet grew three implementations of this — a Python script, and two
# copies of `marocchino/sticky-pull-request-comment`. They agree on the behaviour and differ on
# everything else, so this is that behaviour with the differences removed.
#
# **Failure-isolated.** A deploy that worked and a comment that did not is a successful deploy.
# Failing the job here would invite a re-run, and a re-run deploys again to fix a comment.
#
# Uses `curl` against `$GITHUB_API_URL` rather than `gh`, so it works unchanged on
# github.com, ghe.com and GHES, and needs nothing installed on the runner.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
PR_NUMBER="${PR_NUMBER:-}"
COMMENT_KEY="${COMMENT_KEY:-deploy}"
BODY_FILE="${BODY_FILE:-}"
BODY="${BODY:-}"

if [[ -z "$PR_NUMBER" ]]; then
  tremvok::log "no pull request in scope; not posting a comment"
  exit 0
fi
if [[ -z "$AUTH_TOKEN" ]]; then
  tremvok::warn "no token available for the pull-request comment (needs pull-requests: write); skipping it. The deploy itself is unaffected."
  exit 0
fi

[[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] && BODY="$(cat "$BODY_FILE")"
[[ -n "$BODY" ]] || tremvok::fail "notify-pr needs BODY or BODY_FILE"

marker="<!-- tremvok:${COMMENT_KEY} -->"
payload_body="${marker}"$'\n'"${BODY}"

# GitHub refuses a comment over 65,536 characters with a 422. Callers keep inside that (the
# terragrunt plan comment sizes its excerpts to fit); this is the backstop, so an oversized body
# still posts, cut short and saying so, instead of the comment silently never updating.
MAX_COMMENT_CHARS="${MAX_COMMENT_CHARS:-65000}"
if (( ${#payload_body} > MAX_COMMENT_CHARS )); then
  cut_note=$'\n\n_Cut short to fit GitHub\'s comment size limit; the workflow run has the full output._'
  payload_body="${payload_body:0:$(( MAX_COMMENT_CHARS - ${#cut_note} ))}${cut_note}"
fi

api() {
  curl --silent --show-error --location --max-time 20 \
    --header "authorization: Bearer ${AUTH_TOKEN}" \
    --header 'accept: application/vnd.github+json' \
    --header 'x-github-api-version: 2022-11-28' \
    "$@"
}

# The comment id to edit, or empty. Paginated because a busy pull request easily passes 100
# comments, and a `grep` over only the first page silently starts posting a second comment on
# exactly the pull requests that most need one comment.
find_comment_id() {
  local page=1 body ids
  while (( page <= 10 )); do
    body="$(api "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100&page=${page}")" || return 1
    ids="$(jq -r --arg marker "$marker" '[.[] | select(.body != null and (.body | contains($marker))) | .id] | last // empty' <<<"$body")" || return 1
    [[ -n "$ids" ]] && { printf '%s' "$ids"; return 0; }
    [[ "$(jq 'length' <<<"$body")" -eq 100 ]] || return 0
    page=$(( page + 1 ))
  done
  return 0
}

# The request reaches curl as a file and the body reaches jq on stdin, never as an argument. A
# comment near GitHub's limit is past the kernel's 128 KiB cap on a single argument once it is
# JSON-escaped, and that failure ("Argument list too long") surfaced only as "could not post".
request_file="$(mktemp)"
trap 'rm -f "$request_file"' EXIT
printf '%s' "$payload_body" | jq -Rs '{body: .}' >"$request_file"

if ! comment_id="$(find_comment_id)"; then
  tremvok::warn "could not read the pull-request comments; skipping the sticky comment."
  exit 0
fi

if [[ -n "$comment_id" ]]; then
  if api --fail --request PATCH --data-binary @"$request_file" \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" >/dev/null; then
    tremvok::log "updated pull-request comment ${comment_id}"
  else
    tremvok::warn "could not update the pull-request comment; the deploy is unaffected."
  fi
else
  if api --fail --request POST --data-binary @"$request_file" \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" >/dev/null; then
    tremvok::log "posted a new pull-request comment"
  else
    tremvok::warn "could not post the pull-request comment; the deploy is unaffected."
  fi
fi
