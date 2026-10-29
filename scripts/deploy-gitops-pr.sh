#!/usr/bin/env bash
# The gitops-pr target: deploy a released image through the kustomize overlays a GitOps
# controller applies, by pull request, one overlay at a time.
#
# WHAT IT DOES, BY EVENT
#
#   release (published)  Open the deploy PR for the FIRST overlay, moving every image in
#                        `gitops-images` to the release's tag. A prerelease is skipped
#                        unless `gitops-prereleases` is on. Diatreme publishes the GitHub
#                        Release after the image is in the registry, which is why this is
#                        the event to start from.
#   push                 A deploy PR merged into `gitops-base`. Open the deploy PR for the
#                        overlay after the one it moved, with exactly the tags the merge
#                        moved there, so the next environment only ever gets a build the
#                        previous one ran. Any other push is ignored.
#   anything, with       Open the deploy PR for the first overlay at that tag: a deploy by
#   `gitops-tag` set     hand, or a re-run.
#
# RELEASE CANDIDATES (`gitops-prereleases-until`)
#
# Set to an overlay, it splits the chain in two. A prerelease is deployed up to and including
# that overlay and stops there. A stable release whose own prerelease that overlay already runs
# (v1.4.0 while acc runs v1.4.0-rc.2) starts at the overlay after it: the candidate was signed
# off and released as the same image, so it goes on to production under its stable tag without
# a second trip through acceptance. A stable release with no candidate running there starts at
# the first overlay, as without the input. Either way production only gets what acceptance ran.
#
# Tremvok never applies anything to a cluster. Merging a deploy PR is the deployment, and the
# controller does the applying; a run the merge starts can prove the result with `verify-url`.
# There is no preview: a pull request is how this target deploys, so it has nothing to publish
# somewhere disposable, and a pull_request run says so and deploys nothing.
#
# WHAT IS PROMOTED ON A MERGE
#
# What the merge changed, read from the merged overlay itself: its image tags at the merge
# commit against the merge commit's first parent, for the images in `gitops-images`. That is
# what the overlay runs now, a reviewer's edit on the branch included, and an image the pull
# request did not move is not carried along.
#
# Env: MODE, DRY_RUN, EVENT_NAME, EVENT_PATH, SHA, REF_NAME, DEFAULT_BRANCH, GITHUB_API_URL,
#      GITHUB_REPOSITORY, AUTH_TOKEN, OVERLAYS, IMAGES, TAG, BASE, BRANCH_PREFIX, PRERELEASES,
#      PRERELEASES_UNTIL
# Outputs: deployed, url, version-id, number, result
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
EVENT_NAME="${EVENT_NAME:-}"
EVENT_PATH="${EVENT_PATH:-${GITHUB_EVENT_PATH:-}}"
SHA="${SHA:-${GITHUB_SHA:-}}"
REF_NAME="${REF_NAME:-${GITHUB_REF_NAME:-}}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
AUTH_TOKEN="${AUTH_TOKEN:-${GITHUB_TOKEN:-}}"
OVERLAYS="${OVERLAYS:-}"
IMAGES="${IMAGES:-}"
TAG="${TAG:-}"
BASE="${BASE:-}"
BRANCH_PREFIX="${BRANCH_PREFIX:-deploy}"
PRERELEASES="${PRERELEASES:-false}"
PRERELEASES_UNTIL="${PRERELEASES_UNTIL:-}"

export GITHUB_API_URL GITHUB_REPOSITORY AUTH_TOKEN BRANCH_PREFIX DRY_RUN

tremvok::set_output deployed false

case "$MODE" in
  preview)
    tremvok::notice "gitops-pr deploys by opening a pull request, so a pull request has nothing to preview. Nothing was deployed."
    exit 0
    ;;
  rollback)
    tremvok::fail "gitops-pr has no rollback of its own: revert the deploy PR's merge, which goes through review like the deploy did."
    ;;
esac

tremvok::require OVERLAYS "gitops-overlays"
tremvok::require IMAGES "gitops-images"
tremvok::require GITHUB_REPOSITORY

# ── The overlays, in order, and the images ─────────────────────────────────────────────
# Whitespace-separated, so a YAML block scalar with one per line and a one-line list both
# work. bash 3.2: no mapfile, so the arrays are filled with read.
overlays=()
while IFS= read -r o; do
  [[ -n "$o" ]] || continue
  o="${o#./}"
  o="${o%/}"
  case "$o" in
    /*) tremvok::fail "gitops-overlays: '${o}' must be a directory relative to the repository root" ;;
  esac
  case "/${o}/" in
    */../*|*/./*) tremvok::fail "gitops-overlays: '${o}' must not contain '.' or '..' segments" ;;
  esac
  overlays+=("$o")
done < <(printf '%s\n' "$OVERLAYS" | tr -s '[:blank:]' '\n')
[[ "${#overlays[@]}" -gt 0 ]] || tremvok::fail "gitops-overlays names no overlay"

dup="$(printf '%s\n' "${overlays[@]}" | sed 's#.*/##' | sort | uniq -d | head -n 1)"
[[ -z "$dup" ]] \
  || tremvok::fail "gitops-overlays: more than one overlay is called '${dup}'; the name is what the deploy PR branch carries, so it has to be unique"

images=()
while IFS= read -r i; do
  [[ -n "$i" ]] && images+=("$i")
done < <(printf '%s\n' "$IMAGES" | tr -s '[:blank:]' '\n')
[[ "${#images[@]}" -gt 0 ]] || tremvok::fail "gitops-images names no image"
for i in "${images[@]}"; do
  case "${i##*/}" in
    *:*|*@*) tremvok::fail "gitops-images: '${i}' carries a tag or digest; name the repository only, the tag is what a deploy sets" ;;
  esac
done

name_of() { printf '%s' "${1##*/}"; }

# The overlay after the one called $1, or nothing.
next_after() {
  local i
  for ((i = 0; i < ${#overlays[@]} - 1; i++)); do
    if [[ "$(name_of "${overlays[$i]}")" == "$1" ]]; then
      printf '%s' "${overlays[$((i + 1))]}"
      return 0
    fi
  done
}

# The overlay called $1, or nothing.
overlay_named() {
  local o
  for o in "${overlays[@]}"; do
    if [[ "$(name_of "$o")" == "$1" ]]; then printf '%s' "$o"; return 0; fi
  done
}

# The release tag for every image, as the JSON object gitops-open-pr.sh takes.
images_at() {
  printf '%s\n' "${images[@]}" | jq -Rn --arg t "$1" '[inputs | {key: ., value: $t}] | from_entries'
}

managed="$(printf '%s\n' "${images[@]}" | jq -Rn '[inputs]')"

# The position of the overlay called $1 in gitops-overlays.
index_of() {
  local i
  for ((i = 0; i < ${#overlays[@]}; i++)); do
    if [[ "$(name_of "${overlays[$i]}")" == "$1" ]]; then printf '%s' "$i"; return 0; fi
  done
  printf '%s' -1
}

# ── Where prereleases stop ─────────────────────────────────────────────────────────────
until_name=""
if [[ -n "$PRERELEASES_UNTIL" ]]; then
  u="${PRERELEASES_UNTIL#./}"
  u="${u%/}"
  until_name="$(name_of "$u")"
  until_path="$(overlay_named "$until_name")"
  if [[ -z "$until_path" ]] || [[ "$u" == */* && "$u" != "$until_path" ]]; then
    tremvok::fail "gitops-prereleases-until: '${PRERELEASES_UNTIL}' is not one of gitops-overlays"
  fi
  [[ -n "$(next_after "$until_name")" ]] \
    || tremvok::fail "gitops-prereleases-until: '${until_name}' is the last overlay, so a stable release would have nowhere left to go. Leave it empty to send prereleases through every overlay."
fi

# A SemVer prerelease: a version core, a hyphen, identifiers (v1.4.0-rc.2).
is_prerelease() { [[ "$1" =~ [0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$ ]]; }

# Does tag $2 stop at overlay $1? A prerelease does, at the until overlay and any after it.
stops_at() {
  [[ -n "$until_name" ]] && is_prerelease "$2" && (($(index_of "$1") >= $(index_of "$until_name")))
}

# The overlay a deploy PR for tag $2 on overlay $1 hands on to when it merges, or nothing.
hand_on_to() {
  if stops_at "$1" "$2"; then return 0; fi
  next_after "$1"
}

base="$BASE"
if [[ -z "$base" ]]; then
  if [[ "$EVENT_NAME" == "push" ]]; then base="$REF_NAME"; else base="$DEFAULT_BRANCH"; fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

open_pr() { # overlay images tag next source-note
  local out
  out="$(OVERLAY="$1" BASE="$base" IMAGES="$2" TAG="$3" NEXT_OVERLAY="$4" SOURCE_NOTE="$5" \
    GITHUB_OUTPUT="${WORK}/open.out" bash "${here}/gitops-open-pr.sh")" || { printf '%s\n' "$out"; exit 1; }
  printf '%s\n' "$out"
  local key value result=""
  while IFS='=' read -r key value; do
    case "$key" in
      url) tremvok::set_output url "$value" ;;
      number) tremvok::set_output number "$value" ;;
      result) result="$value"; tremvok::set_output result "$value" ;;
    esac
  done <"${WORK}/open.out"
  tremvok::set_output version-id "$3"
  case "$result" in
    created|refreshed) tremvok::set_output deployed true ;;
  esac
}

first="${overlays[0]}"

# The managed images' tags in overlay $1 at ref $2, as {image: tag}. An overlay that did not
# exist yet reads as no images.
overlay_tags() {
  local overlay="$1" ref="$2" f code
  for f in kustomization.yaml kustomization.yml Kustomization; do
    code="$(curl --silent --show-error --location --retry 2 --max-time 20 \
      --output "${WORK}/file.json" --write-out '%{http_code}' \
      --header "authorization: Bearer ${AUTH_TOKEN}" \
      --header 'accept: application/vnd.github+json' \
      --header 'x-github-api-version: 2022-11-28' \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/contents/${overlay}/${f}?ref=${ref}")" || code=000
    case "$code" in
      200)
        jq -r '.content' "${WORK}/file.json" | base64 --decode \
          | yq -o=json -I=0 '[(.images // [])[] | select(has("newTag")) | {"key": (.newName // .name), "value": (.newTag | tostring)}] | from_entries' \
          | tr -d '\r'
        return 0 ;;
      404) ;;
      *) tremvok::fail "gitops-pr: reading ${overlay}/${f} at ${ref:0:12} failed (HTTP ${code})" ;;
    esac
  done
  printf '{}'
}

# Does the until overlay run a prerelease of stable tag $1 (v1.4.0-rc.2 for v1.4.0) for
# every managed image it lists?
candidate_runs() {
  local current
  current="$(overlay_tags "$(overlay_named "$until_name")" "$base")"
  jq -e --arg t "$1" --argjson m "$managed" '
    [to_entries[] | select(.key as $k | $m | index($k))] as $e
    | ($e | length) > 0 and ($e | all(.value | startswith($t + "-")))' <<<"$current" >/dev/null
}

# ── A tag by hand ──────────────────────────────────────────────────────────────────────
if [[ -n "$TAG" ]]; then
  : >"${WORK}/open.out"
  open_pr "$first" "$(images_at "$TAG")" "$TAG" "$(name_of "$(hand_on_to "$(name_of "$first")" "$TAG")")" \
    "Requested by hand, from run ${GITHUB_RUN_ID:-this run}."
  exit 0
fi

case "$EVENT_NAME" in
  release)
    [[ -n "$EVENT_PATH" && -f "$EVENT_PATH" ]] || tremvok::fail "gitops-pr: the release event payload is missing"
    tag="$(jq -r '.release.tag_name // empty' "$EVENT_PATH")"
    [[ -n "$tag" ]] || tremvok::fail "gitops-pr: the release event carries no tag_name"
    if [[ "$(jq -r '.release.prerelease // false' "$EVENT_PATH")" == "true" ]] && ! tremvok::is_true "$PRERELEASES"; then
      tremvok::notice "gitops-pr: ${tag} is a prerelease; only stable releases are deployed (set gitops-prereleases: true to change that). Nothing was deployed."
      exit 0
    fi
    link="$(jq -r '.release.html_url // empty' "$EVENT_PATH")"
    note="Released as \`${tag}\`."
    [[ -z "$link" ]] || note="Released as [\`${tag}\`](${link})."
    target="$first"
    if [[ -n "$until_name" ]] && ! is_prerelease "$tag" && candidate_runs "$tag"; then
      target="$(next_after "$until_name")"
      note="${note} **${until_name}** already runs its release candidate, so it goes straight to **$(name_of "$target")**."
      tremvok::log "${until_name} runs a release candidate of ${tag}; deploying it to $(name_of "$target")"
    fi
    : >"${WORK}/open.out"
    open_pr "$target" "$(images_at "$tag")" "$tag" "$(name_of "$(hand_on_to "$(name_of "$target")" "$tag")")" "$note"
    ;;

  push)
    [[ -n "$SHA" ]] || tremvok::fail "gitops-pr: a push run needs the pushed commit"
    rc=0
    number="$(SHA="$SHA" BASE_REF="$REF_NAME" bash "${here}/resolve-merged-pr.sh")" || rc=$?
    case "$rc" in
      0) ;;
      2) tremvok::notice "gitops-pr: ${SHA:0:12} came from no merged pull request (a direct push); nothing to promote."; exit 0 ;;
      *) tremvok::fail "gitops-pr: could not tell which pull request ${SHA:0:12} came from" ;;
    esac
    code="$(curl --silent --show-error --location --retry 2 --max-time 20 \
      --output "${WORK}/pr.json" --write-out '%{http_code}' \
      --header "authorization: Bearer ${AUTH_TOKEN}" \
      --header 'accept: application/vnd.github+json' \
      --header 'x-github-api-version: 2022-11-28' \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/${number}")" || code=000
    [[ "$code" == "200" ]] || tremvok::fail "gitops-pr: could not read pull request #${number} (HTTP ${code})"
    head="$(jq -r '.head.ref' "${WORK}/pr.json")"
    prefix="${BRANCH_PREFIX%/}"
    case "$head" in
      "${prefix}"/*/*) ;;
      *) tremvok::notice "gitops-pr: #${number} (${head}) is not a deploy PR; nothing to promote."; exit 0 ;;
    esac
    rest="${head#"${prefix}"/}"
    name="${rest%%/*}"
    source_overlay="$(overlay_named "$name")"
    if [[ -z "$source_overlay" ]]; then
      tremvok::warn "gitops-pr: #${number} came from ${head}, but gitops-overlays has no overlay called '${name}'; nothing to promote."
      exit 0
    fi
    next="$(next_after "$name")"
    if [[ -z "$next" ]]; then
      tremvok::notice "gitops-pr: ${source_overlay} is the last overlay; nothing to promote."
      exit 0
    fi

    code="$(curl --silent --show-error --location --retry 2 --max-time 20 \
      --output "${WORK}/commit.json" --write-out '%{http_code}' \
      --header "authorization: Bearer ${AUTH_TOKEN}" \
      --header 'accept: application/vnd.github+json' \
      --header 'x-github-api-version: 2022-11-28' \
      "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/commits/${SHA}")" || code=000
    [[ "$code" == "200" ]] || tremvok::fail "gitops-pr: could not read commit ${SHA:0:12} (HTTP ${code})"
    parent="$(jq -r '.parents[0].sha // empty' "${WORK}/commit.json")"
    [[ -n "$parent" ]] || tremvok::fail "gitops-pr: commit ${SHA:0:12} has no parent to compare with"

    before="$(overlay_tags "$source_overlay" "$parent")"
    after="$(overlay_tags "$source_overlay" "$SHA")"
    changed="$(jq -cn --argjson b "$before" --argjson a "$after" --argjson m "$managed" \
      '$a | with_entries(select((.key as $k | $m | index($k)) and $b[.key] != .value))')"
    if [[ "$(jq 'length' <<<"$changed")" == "0" ]]; then
      tremvok::warn "gitops-pr: #${number} merged without moving a tag in gitops-images in ${source_overlay}; nothing to promote."
      exit 0
    fi
    # One tag names the pull request. A release moves every image to the same tag; should a
    # reviewer have left them apart, the newest one names it.
    tag="$(jq -r '.[]' <<<"$changed" | sort -V | tail -n 1)"
    if stops_at "$name" "$tag"; then
      tremvok::notice "gitops-pr: ${tag} is a prerelease, and prereleases stop at ${until_name} (gitops-prereleases-until). Release it as a stable version to deploy it further."
      exit 0
    fi
    after_next="$(hand_on_to "$(name_of "$next")" "$tag")"
    tremvok::log "promoting ${changed} from ${source_overlay} (#${number}) to ${next}"
    : >"${WORK}/open.out"
    open_pr "$next" "$changed" "$tag" "$(name_of "$after_next")" \
      "**$(name_of "$source_overlay")** runs it since #${number} merged."
    ;;

  *)
    tremvok::fail "gitops-pr runs on a published release, on a push to ${base} that merged a deploy PR, or with gitops-tag set; this run is a '${EVENT_NAME}' event."
    ;;
esac
