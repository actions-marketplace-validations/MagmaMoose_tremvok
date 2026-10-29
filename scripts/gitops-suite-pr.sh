#!/usr/bin/env bash
# Accumulate independently versioned images in one promotion PR per overlay.
# Uses signed contents-API commits and merges the base into an existing branch.
# Env: OVERLAY BASE IMAGES (JSON image->tag), AUTH_TOKEN, GITHUB_REPOSITORY,
# GITHUB_API_URL, BRANCH_PREFIX (chore/promote), RELEASE_REPOSITORIES (JSON
# image->owner/repository for final release links), GITHUB_SERVER_URL,
# ALLOWED_ACTORS (comma/whitespace-separated manual operators), ALLOW_DOWNGRADE,
# DRY_RUN. Manual dispatch requires both original and rerun actors to be allowed.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
OVERLAY="${OVERLAY:-}"
BASE="${BASE:-}"
IMAGES="${IMAGES:-}"
BRANCH_PREFIX="${BRANCH_PREFIX:-chore/promote}"
RELEASE_REPOSITORIES="${RELEASE_REPOSITORIES:-}"
[[ -n "$RELEASE_REPOSITORIES" ]] || RELEASE_REPOSITORIES='{}'
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-}"
if [[ -z "$GITHUB_SERVER_URL" ]]; then
  if [[ "$GITHUB_API_URL" == https://api.github.com ]]; then GITHUB_SERVER_URL=https://github.com
  else GITHUB_SERVER_URL="${GITHUB_API_URL%/api/v3}"; fi
fi
ALLOW_DOWNGRADE="${ALLOW_DOWNGRADE:-false}"
DRY_RUN="${DRY_RUN:-false}"
tremvok::require GITHUB_REPOSITORY
tremvok::require AUTH_TOKEN
tremvok::require OVERLAY
tremvok::require BASE
tremvok::require IMAGES

if [[ "${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}" == workflow_dispatch ]]; then
  allowed="$(printf '%s' "${ALLOWED_ACTORS:-}" | tr ',[:space:]' '\n' | tr '[:upper:]' '[:lower:]' | sed '/^$/d')"
  [[ -n "$allowed" ]] || tremvok::fail 'gitops-suite: manual operators are not configured; nobody may override'
  for operator in "${GITHUB_ACTOR:-}" "${GITHUB_TRIGGERING_ACTOR:-}"; do
    [[ -n "$operator" ]] || tremvok::fail 'gitops-suite: manual actor or triggering_actor is missing'
    actor="$(printf '%s' "$operator" | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$allowed" | grep -Fxq "$actor" \
      || tremvok::fail "gitops-suite: ${operator} is not an allowed manual operator"
  done
elif tremvok::is_true "$ALLOW_DOWNGRADE"; then
  tremvok::fail 'gitops-suite: a downgrade requires an authorised manual dispatch'
fi

OVERLAY="${OVERLAY#./}"; OVERLAY="${OVERLAY%/}"
case "/${OVERLAY}/" in
  //*/|*/../*|*/./*) tremvok::fail 'gitops-suite: overlay must be a repository-relative directory without dot segments' ;;
esac
NAME="${OVERLAY##*/}"
BRANCH="${BRANCH_PREFIX%/}/${NAME}"
# These names go into API paths; refuse ambiguous or unsafe ref names.
REF_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
for ref in "$BASE" "$BRANCH"; do
  [[ "$ref" =~ $REF_RE ]] || tremvok::fail 'gitops-suite: invalid branch name'
  case "$ref" in *..*|*//*|*/|*.lock|*@*) tremvok::fail 'gitops-suite: invalid branch name' ;; esac
done
jq -e 'type == "object" and length > 0 and all(to_entries[]; (.key | test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$")) and (.value | type == "string"))' <<<"$IMAGES" >/dev/null 2>&1 \
  || tremvok::fail 'gitops-suite: IMAGES must map image repositories to tags'
jq -e 'type == "object" and all(to_entries[]; (.key | test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$")) and (.value | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")))' <<<"$RELEASE_REPOSITORIES" >/dev/null 2>&1 \
  || tremvok::fail 'gitops-suite: RELEASE_REPOSITORIES must map images to owner/repository names'
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
while IFS= read -r tag; do
  [[ "$tag" =~ $TAG_RE ]] || tremvok::fail 'gitops-suite: invalid image tag'
done < <(jq -r '.[]' <<<"$IMAGES")
command -v yq >/dev/null || tremvok::fail 'gitops-suite requires mikefarah/yq v4'

TASK_WORK="$(mktemp -d)"
trap 'rm -rf "$TASK_WORK"' EXIT
API="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}"
http() {
  local method="$1" url="$2" data="${3:-}" code
  local args=(--silent --show-error --location --retry 2 --max-time 30
    --output "${TASK_WORK}/response" --write-out '%{http_code}'
    --header "authorization: Bearer ${AUTH_TOKEN}"
    --header 'accept: application/vnd.github+json'
    --header 'x-github-api-version: 2022-11-28' --request "$method")
  [[ -z "$data" ]] || args+=(--header 'content-type: application/json' --data-binary "@${data}")
  code="$(curl "${args[@]}" "$url")" || code=000
  printf '%s' "$code"
}
must() {
  local code
  code="$(http "$1" "$2" "${3:-}")"
  [[ "$code" == 2?? ]] || tremvok::fail "gitops-suite: ${4:-API request} failed (HTTP ${code})"
}
yqv() { yq "$@" | tr -d '\r'; }
SEL='(.images // [])[] | select((.newName // .name) == strenv(GITOPS_IMAGE))'
read_file() {
  must GET "${API}/contents/${FILE}?ref=$1" '' 'reading overlay'
  BLOB_SHA="$(jq -r '.sha' "${TASK_WORK}/response")"
  jq -er '.content' "${TASK_WORK}/response" | base64 --decode >"$2"
}
set_tag() {
  local file="$1" image="$2" tag="$3" count line
  export GITOPS_IMAGE="$image"
  count="$(yqv "[${SEL}] | length" "$file")"
  [[ "$count" == 1 ]] || tremvok::fail "gitops-suite: expected exactly one images entry for ${image}"
  [[ "$(yqv "${SEL} | has(\"digest\")" "$file")" == false ]] \
    || tremvok::fail "gitops-suite: ${image} is pinned by digest"
  [[ "$(yqv "${SEL} | has(\"newTag\")" "$file")" == true ]] \
    || tremvok::fail "gitops-suite: ${image} has no newTag"
  line="$(yqv "${SEL} | .newTag | line" "$file")"
  sed -E "${line}s/^([[:space:]]*(-[[:space:]]+)?newTag:[[:space:]]*)([\"']?)[A-Za-z0-9_][A-Za-z0-9._-]*([\"']?)/\\1\\3${tag}\\4/" "$file" >"${TASK_WORK}/edited"
  mv "${TASK_WORK}/edited" "$file"
  [[ "$(yqv "${SEL} | .newTag" "$file")" == "$tag" ]] \
    || tremvok::fail 'gitops-suite: newTag must use block-style YAML'
}

must GET "${API}/git/ref/heads/${BASE}" '' 'reading base branch'
BASE_SHA="$(jq -er '.object.sha' "${TASK_WORK}/response")"
FILE=''
for file in kustomization.yaml kustomization.yml Kustomization; do
  code="$(http GET "${API}/contents/${OVERLAY}/${file}?ref=${BASE_SHA}")"
  case "$code" in
    200) FILE="${OVERLAY}/${file}"; break ;;
    404) ;;
    *) tremvok::fail "gitops-suite: reading overlay failed (HTTP ${code})" ;;
  esac
done
[[ -n "$FILE" ]] || tremvok::fail 'gitops-suite: overlay has no kustomization file'
BLOB_SHA="$(jq -er '.sha' "${TASK_WORK}/response")"
jq -er '.content' "${TASK_WORK}/response" | base64 --decode >"${TASK_WORK}/base"

printf '[]' >"${TASK_WORK}/prs"
page=1
while :; do
  must GET "${API}/pulls?state=open&base=${BASE}&per_page=100&page=${page}" '' 'listing promotion PRs'
  jq -e 'type == "array"' "${TASK_WORK}/response" >/dev/null \
    || tremvok::fail 'gitops-suite: malformed pull request response'
  count="$(jq length "${TASK_WORK}/response")"
  jq --arg b "$BRANCH" --arg r "$GITHUB_REPOSITORY" \
    '[.[] | select(.head.ref == $b and .head.repo.full_name == $r)]' "${TASK_WORK}/response" >"${TASK_WORK}/page"
  jq -s 'add' "${TASK_WORK}/prs" "${TASK_WORK}/page" >"${TASK_WORK}/all"
  mv "${TASK_WORK}/all" "${TASK_WORK}/prs"
  [[ "$count" -eq 100 ]] || break
  page=$((page + 1))
done
count="$(jq length "${TASK_WORK}/prs")"
[[ "$count" -le 1 ]] || tremvok::fail 'gitops-suite: multiple promotion PRs match this environment'
number="$(jq -r '.[0].number // empty' "${TASK_WORK}/prs")"
if [[ -n "$number" ]]; then
  must GET "${API}/git/ref/heads/${BRANCH}" '' 'reading promotion branch'
  HEAD_SHA="$(jq -er '.object.sha' "${TASK_WORK}/response")"
  read_file "$HEAD_SHA" "${TASK_WORK}/pending"
  if ! tremvok::is_true "$DRY_RUN"; then
    jq -n --arg base "$BRANCH" --arg head "$BASE_SHA" '{base:$base, head:$head, commit_message:"chore(promote): merge current base"}' >"${TASK_WORK}/merge"
    must POST "${API}/merges" "${TASK_WORK}/merge" 'merging base into promotion branch (resolve conflicts before retrying)'
    must GET "${API}/git/ref/heads/${BRANCH}" '' 'reading merged promotion branch'
    HEAD_SHA="$(jq -er '.object.sha' "${TASK_WORK}/response")"
    read_file "$HEAD_SHA" "${TASK_WORK}/pending"
  fi
else
  cp "${TASK_WORK}/base" "${TASK_WORK}/pending"
fi
cp "${TASK_WORK}/pending" "${TASK_WORK}/after"
while IFS=$'\t' read -r image tag; do
  count="$(GITOPS_IMAGE="$image" yqv "[${SEL}] | length" "${TASK_WORK}/after")"
  [[ "$count" == 1 ]] || tremvok::fail "gitops-suite: expected exactly one images entry for ${image}"
  old="$(GITOPS_IMAGE="$image" yqv "${SEL} | .newTag" "${TASK_WORK}/after")"
  current="$(GITOPS_IMAGE="$image" yqv "${SEL} | .newTag" "${TASK_WORK}/base")"
  if ! tremvok::is_true "$ALLOW_DOWNGRADE" && { tremvok::version_gt "$old" "$tag" || tremvok::version_gt "$current" "$tag"; }; then
    tremvok::notice "gitops-suite: leaving newer ${image} at ${old}; skipped stale ${tag}"
    continue
  fi
  set_tag "${TASK_WORK}/after" "$image" "$tag"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$IMAGES")

# Render every outstanding image change against the current base, including prior runs.
yqv -o=json '[(.images // [])[] | {"key": (.newName // .name), "value": (.newTag | tostring)}] | from_entries' "${TASK_WORK}/base" >"${TASK_WORK}/base-tags"
yqv -o=json '[(.images // [])[] | {"key": (.newName // .name), "value": (.newTag | tostring)}] | from_entries' "${TASK_WORK}/after" >"${TASK_WORK}/after-tags"
jq -nr --slurpfile b "${TASK_WORK}/base-tags" --slurpfile a "${TASK_WORK}/after-tags" \
  '$a[0] | to_entries[] | select($b[0][.key] != .value) | [.key, ($b[0][.key] // "none"), .value] | @tsv' >"${TASK_WORK}/changes"
if [[ ! -s "${TASK_WORK}/changes" && -z "$number" ]]; then
  tremvok::set_output result unchanged
  exit 0
fi

TITLE="chore(promote): release to ${NAME}"
{
  printf 'Promotes the pending image versions to %s.\n\n' "$NAME"
  printf '| Image | Current | After merge | Release notes |\n| --- | --- | --- | --- |\n'
  while IFS=$'\t' read -r image old tag; do
    repository="$(jq -r --arg image "$image" '.[$image] // empty' <<<"$RELEASE_REPOSITORIES")"
    link=''
    [[ -z "$repository" ]] || link="[Changes](${GITHUB_SERVER_URL%/}/${repository}/releases/tag/${tag})"
    # shellcheck disable=SC2016  # Backticks delimit Markdown code spans in the printf format.
    printf '| `%s` | `%s` | `%s` | %s |\n' "$image" "$old" "$tag" "$link"
  done <"${TASK_WORK}/changes"
  printf '\nMerging this PR promotes all listed images together.\n'
} >"${TASK_WORK}/body"
if tremvok::is_true "$DRY_RUN"; then
  tremvok::set_output result planned
  exit 0
fi
if [[ -z "$number" ]]; then
  code="$(http GET "${API}/git/ref/heads/${BRANCH}")"
  case "$code" in
    200) must DELETE "${API}/git/refs/heads/${BRANCH}" '' 'removing orphan promotion branch' ;;
    404) ;;
    *) tremvok::fail "gitops-suite: reading orphan branch failed (HTTP ${code})" ;;
  esac
  jq -n --arg ref "refs/heads/${BRANCH}" --arg sha "$BASE_SHA" '{ref:$ref,sha:$sha}' >"${TASK_WORK}/ref"
  must POST "${API}/git/refs" "${TASK_WORK}/ref" 'creating promotion branch'
fi
if ! cmp -s "${TASK_WORK}/pending" "${TASK_WORK}/after"; then
  jq -n --arg message "$TITLE" --arg branch "$BRANCH" --arg sha "$BLOB_SHA" \
    --arg content "$(base64 <"${TASK_WORK}/after" | tr -d '\n')" \
    '{message:$message,branch:$branch,sha:$sha,content:$content}' >"${TASK_WORK}/put"
  must PUT "${API}/contents/${FILE}" "${TASK_WORK}/put" 'committing selected images'
fi
read_file "$BRANCH" "${TASK_WORK}/committed"
cmp -s "${TASK_WORK}/after" "${TASK_WORK}/committed" \
  || tremvok::fail 'gitops-suite: promotion branch did not retain the selected images; PR was not updated'
if [[ -n "$number" ]]; then
  jq -n --arg title "$TITLE" --rawfile body "${TASK_WORK}/body" '{title:$title,body:$body}' >"${TASK_WORK}/pr"
  must PATCH "${API}/pulls/${number}" "${TASK_WORK}/pr" 'refreshing promotion PR'
  result=refreshed
else
  jq -n --arg title "$TITLE" --arg head "$BRANCH" --arg base "$BASE" --rawfile body "${TASK_WORK}/body" \
    '{title:$title,head:$head,base:$base,body:$body}' >"${TASK_WORK}/pr"
  must POST "${API}/pulls" "${TASK_WORK}/pr" 'opening promotion PR'
  number="$(jq -er '.number' "${TASK_WORK}/response")"
  result=created
fi
tremvok::set_output url "$(jq -er '.html_url' "${TASK_WORK}/response")"
tremvok::set_output number "$number"
tremvok::set_output result "$result"
