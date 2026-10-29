#!/usr/bin/env bats
#
# The gitops-pr target against a curl stub that holds a small GitHub: branches, files at a
# ref, open pull requests, and the writes the target makes. What is pinned here is what a
# reviewer relies on: the deploy PR moves exactly the tag line and nothing else, one overlay
# has one open deploy PR, an overlay is never moved backwards, a merge promotes exactly what
# it changed, and a pull request run deploys nothing.

load helper

IMG="containers.example/acme/app"

setup() {
  setup_common
  command -v yq >/dev/null || skip "yq not installed"
  export GITHUB_REPOSITORY=acme/app
  export GITHUB_API_URL=https://api.example
  export AUTH_TOKEN=ghs_test
  export STATE="${WORK}/gh"
  mkdir -p "${STATE}/refs" "${STATE}/files"
  echo '[]' >"${STATE}/prs.json"
  export STUB_PR_URL="https://example/acme/app/pull/42"

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
# A little GitHub. Writes the response body to --output (or stdout), prints the status for
# --write-out, and honours --fail.
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
method=GET out="" data="" writeout="" fail=false url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --write-out) writeout="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --header|--max-time|--retry) shift 2 ;;
    --fail) fail=true; shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#"${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/"}"
query=""
case "$path" in *\?*) query="${path#*\?}"; path="${path%%\?*}" ;; esac
ref="$(printf '%s' "$query" | sed -n 's/.*ref=\([^&]*\).*/\1/p')"
key() { printf '%s' "$1" | sed 's#/#__#g'; }
status=200 body='{}'
file_at() {
  if [ -f "${STATE}/files@$1/$2" ]; then cat "${STATE}/files@$1/$2"
  elif [ -f "${STATE}/files/$2" ]; then cat "${STATE}/files/$2"
  else return 1; fi
}
case "${method} ${path}" in
  "GET git/ref/heads/"*)
    b="${path#git/ref/heads/}"
    if [ -f "${STATE}/refs/$(key "$b")" ]; then body="{\"object\":{\"sha\":\"$(cat "${STATE}/refs/$(key "$b")")\"}}"
    else status=404 body='{"message":"Not Found"}'; fi ;;
  "POST git/refs")
    b="$(jq -r '.ref' "$data" | sed 's#^refs/heads/##')"
    jq -r '.sha' "$data" >"${STATE}/refs/$(key "$b")"
    echo "POST git/refs $b" >>"${STATE}/writes.log"; status=201 ;;
  "DELETE git/refs/heads/"*)
    b="${path#git/refs/heads/}"; rm -f "${STATE}/refs/$(key "$b")"
    echo "DELETE $b" >>"${STATE}/writes.log"; status=204 body='' ;;
  "GET contents/"*)
    f="${path#contents/}"
    if c="$(file_at "$ref" "$f")"; then
      body="{\"sha\":\"blob-${ref}\",\"content\":\"$(printf '%s\n' "$c" | base64 | tr -d '\n')\"}"
    else status=404 body='{"message":"Not Found"}'; fi ;;
  "PUT contents/"*)
    f="${path#contents/}"; b="$(jq -r '.branch' "$data")"
    cp "$data" "${STATE}/put.json"
    mkdir -p "${STATE}/files@${b}/$(dirname "$f")"
    jq -r '.content' "$data" | base64 --decode >"${STATE}/files@${b}/${f}"
    echo "PUT $f $b" >>"${STATE}/writes.log"; status=201 ;;
  "GET pulls")
    body="$(cat "${STATE}/prs.json")" ;;
  "POST pulls")
    cp "$data" "${STATE}/pr-create.json"
    body="{\"number\":42,\"html_url\":\"${STUB_PR_URL}\"}"; status=201 ;;
  "PATCH pulls/"*)
    n="${path#pulls/}"; cp "$data" "${STATE}/patch-${n}.json"
    echo "PATCH $n $(jq -c . "$data")" >>"${STATE}/writes.log"
    body="{\"number\":${n},\"html_url\":\"https://example/acme/app/pull/${n}\"}" ;;
  "GET pulls/"*)
    body="$(cat "${STATE}/pr.json")" ;;
  "POST issues/"*"/comments")
    echo "COMMENT ${path}" >>"${STATE}/writes.log"; status=201 ;;
  "POST issues/"*"/labels")
    status=200 ;;
  "GET commits/"*"/pulls")
    body="$(cat "${STATE}/commit-pulls.json")" ;;
  "GET commits/"*)
    body="$(cat "${STATE}/commit.json")" ;;
  *)
    echo "stub: unexpected ${method} ${url}" >&2; status=599 ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
[ -n "$writeout" ] && printf '%s' "$status"
if [ "$fail" = true ] && [ "$status" -ge 400 ]; then exit 22; fi
exit 0
STUBEOF

  printf 'base-sha' >"${STATE}/refs/master"
  mkdir -p "${STATE}/files/k8s/overlays/acc" "${STATE}/files/k8s/overlays/prd"
  cat >"${STATE}/files/k8s/overlays/acc/kustomization.yaml" <<EOF
resources:
  - ../../base

images:
  - name: ${IMG}
    newTag: v1.2.18 # {"\$imagepolicy": "flux-system:acc-app:tag"}
  - name: docker.io/library/redis
    newTag: "7.4"
EOF
  cat >"${STATE}/files/k8s/overlays/prd/kustomization.yaml" <<EOF
images:
  - name: ${IMG}
    newTag: v1.2.18
EOF

  export MODE=deploy BASE=master
  export OVERLAYS=$'k8s/overlays/acc\nk8s/overlays/prd'
  export IMAGES="$IMG"
  release_event v1.2.19 false
}

release_event() {
  export EVENT_NAME=release EVENT_PATH="${WORK}/event.json"
  jq -n --arg t "$1" --argjson p "$2" \
    '{release: {tag_name: $t, prerelease: $p, html_url: ("https://example/acme/app/releases/tag/" + $t)}}' >"$EVENT_PATH"
}

deploy() { run bash "${SCRIPTS}/deploy-gitops-pr.sh"; }
committed() { cat "${STATE}/files@${1}/${2}"; }

@test "a release opens a deploy PR for the first overlay that moves only the tag line" {
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19' "${STATE}/writes.log"
  [ "$(jq -r .sha "${STATE}/put.json")" = "blob-base-sha" ]
  [ "$(jq -r .message "${STATE}/put.json")" = "chore(deploy): v1.2.19 to acc" ]
  run diff "${STATE}/files/k8s/overlays/acc/kustomization.yaml" "${STATE}/files@deploy/acc/v1.2.19/k8s/overlays/acc/kustomization.yaml"
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
  committed deploy/acc/v1.2.19 k8s/overlays/acc/kustomization.yaml | grep -qF '    newTag: v1.2.19 # {"$imagepolicy": "flux-system:acc-app:tag"}'
  committed deploy/acc/v1.2.19 k8s/overlays/acc/kustomization.yaml | grep -qF '    newTag: "7.4"'
  [ "$(jq -r .base "${STATE}/pr-create.json")" = "master" ]
  [ "$(jq -r .head "${STATE}/pr-create.json")" = "deploy/acc/v1.2.19" ]
  jq -r .body "${STATE}/pr-create.json" | grep -qF "| \`${IMG}\` | \`v1.2.18\` | \`v1.2.19\` |"
  jq -r .body "${STATE}/pr-create.json" | grep -qF 'opens the same change for **prd**'
  jq -r .body "${STATE}/pr-create.json" | grep -qF 'Released as [`v1.2.19`](https://example/acme/app/releases/tag/v1.2.19).'
  [ "$(output_value deployed)" = "true" ]
  [ "$(output_value url)" = "$STUB_PR_URL" ]
  [ "$(output_value version-id)" = "v1.2.19" ]
  [ "$(output_value result)" = "created" ]
}

@test "a prerelease opens nothing unless prereleases are on" {
  release_event v1.2.19-rc.1 true
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"is a prerelease"* ]]
  [ ! -f "${STATE}/writes.log" ]
  [ "$(output_value deployed)" = "false" ]
  PRERELEASES=true deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19-rc.1' "${STATE}/writes.log"
}

@test "a pull request run deploys nothing: there is nothing to preview" {
  MODE=preview deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to preview"* ]]
  [ ! -f "${STATE}/writes.log" ]
  [ "$(output_value deployed)" = "false" ]
}

@test "rollback is refused and points at reverting the merge" {
  MODE=rollback deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"revert the deploy PR"* ]]
}

@test "dry run reads and reports, and writes nothing" {
  DRY_RUN=true deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"would open 'chore(deploy): v1.2.19 to acc'"* ]]
  [ ! -f "${STATE}/writes.log" ]
  [ "$(output_value result)" = "planned" ]
}

@test "an overlay that already runs the tag gets no PR, and an older open one is closed" {
  release_event v1.2.18 false
  cat >"${STATE}/prs.json" <<'EOF'
[{"number":7,"html_url":"u7","head":{"ref":"deploy/acc/v1.2.17"}},
 {"number":8,"html_url":"u8","head":{"ref":"deploy/acc/v1.2.20"}},
 {"number":9,"html_url":"u9","head":{"ref":"feature/x"}}]
EOF
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = "unchanged" ]
  [ "$(output_value deployed)" = "false" ]
  grep -q '^PATCH 7 {"state":"closed"}' "${STATE}/writes.log"
  grep -qx 'DELETE deploy/acc/v1.2.17' "${STATE}/writes.log"
  refute grep -q '^PATCH 8' "${STATE}/writes.log"
  refute grep -q '^PATCH 9' "${STATE}/writes.log"
}

@test "a new tag supersedes the open PR for an older one on the same overlay only" {
  cat >"${STATE}/prs.json" <<'EOF'
[{"number":7,"html_url":"u7","head":{"ref":"deploy/acc/v1.2.18"}},
 {"number":5,"html_url":"u5","head":{"ref":"deploy/prd/v1.2.17"}}]
EOF
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = "created" ]
  grep -q '^PATCH 7 {"state":"closed"}' "${STATE}/writes.log"
  grep -qx 'DELETE deploy/acc/v1.2.18' "${STATE}/writes.log"
  refute grep -q '^PATCH 5' "${STATE}/writes.log"
}

@test "a re-run for the same tag refreshes the open PR instead of opening another" {
  echo '[{"number":11,"html_url":"u11","head":{"ref":"deploy/acc/v1.2.19"}}]' >"${STATE}/prs.json"
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = "refreshed" ]
  [ "$(jq -r .title "${STATE}/patch-11.json")" = "chore(deploy): v1.2.19 to acc" ]
  [ ! -f "${STATE}/pr-create.json" ]
  refute grep -q '^POST git/refs' "${STATE}/writes.log"
}

@test "an open PR for a newer tag wins, and an overlay is never moved backwards" {
  echo '[{"number":12,"html_url":"u12","head":{"ref":"deploy/acc/v1.2.20"}}]' >"${STATE}/prs.json"
  deploy
  [ "$status" -eq 0 ]
  [ "$(output_value result)" = "skipped" ]
  [ ! -f "${STATE}/writes.log" ]

  echo '[]' >"${STATE}/prs.json"
  release_event v1.2.10 false
  deploy
  [ "$status" -eq 0 ]
  [ "$(output_value result)" = "skipped" ]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a leftover branch with no open PR is deleted and made again" {
  printf 'stale' >"${STATE}/refs/deploy__acc__v1.2.19"
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'DELETE deploy/acc/v1.2.19' "${STATE}/writes.log"
  grep -qx 'POST git/refs deploy/acc/v1.2.19' "${STATE}/writes.log"
}

@test "an overlay that lists none of the images is an error, and one that lists some warns" {
  IMAGES="containers.example/acme/other" deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"has an images[] entry for none of: containers.example/acme/other"* ]]
  [ ! -f "${STATE}/writes.log" ]

  IMAGES="${IMG} containers.example/acme/worker" deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no images[] entry for containers.example/acme/worker"* ]]
}

@test "a digest-pinned entry, one without newTag, and a flow-style entry are all refused" {
  printf 'images:\n  - name: %s\n    newTag: v1\n    digest: sha256:00\n' "$IMG" >"${STATE}/files/k8s/overlays/acc/kustomization.yaml"
  deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"pins ${IMG} by digest"* ]]

  printf 'images:\n  - name: %s\n    newName: %s\n' "$IMG" "$IMG" >"${STATE}/files/k8s/overlays/acc/kustomization.yaml"
  deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no newTag to move"* ]]

  printf 'images: [{name: %s, newTag: v1.2.18}]\n' "$IMG" >"${STATE}/files/k8s/overlays/acc/kustomization.yaml"
  deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"only a block-style 'newTag: <tag>' line is supported"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "an image given with a tag is refused: the tag is what a deploy sets" {
  IMAGES="${IMG}:v1" deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"carries a tag or digest"* ]]
}

@test "two overlays with one name are refused" {
  OVERLAYS="a/overlays/prd b/overlays/prd" deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one overlay is called 'prd'"* ]]
}

@test "gitops-tag deploys that tag to the first overlay, whatever the event" {
  EVENT_NAME=workflow_dispatch TAG=v1.2.19 deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19' "${STATE}/writes.log"
}

@test "an event it cannot act on fails and says which ones it can" {
  EVENT_NAME=schedule deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"runs on a published release"* ]]
}

merged_push() { # head-ref
  export EVENT_NAME=push SHA=merge-sha REF_NAME=master
  echo '[{"number":31,"merged_at":"2026-10-01T10:00:00Z","base":{"ref":"master"}}]' >"${STATE}/commit-pulls.json"
  jq -n --arg h "$1" '{number: 31, head: {ref: $h}, base: {ref: "master"}}' >"${STATE}/pr.json"
  echo '{"parents":[{"sha":"before-sha"}]}' >"${STATE}/commit.json"
  mkdir -p "${STATE}/files@before-sha/k8s/overlays/acc" "${STATE}/files@merge-sha/k8s/overlays/acc"
  cp "${STATE}/files/k8s/overlays/acc/kustomization.yaml" "${STATE}/files@before-sha/k8s/overlays/acc/kustomization.yaml"
  sed 's/newTag: v1.2.18/newTag: v1.2.19/' "${STATE}/files/k8s/overlays/acc/kustomization.yaml" \
    >"${STATE}/files@merge-sha/k8s/overlays/acc/kustomization.yaml"
}

@test "a merged acc deploy PR opens the prd one with exactly what the merge moved" {
  merged_push deploy/acc/v1.2.19
  unset BASE
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/prd/v1.2.19' "${STATE}/writes.log"
  committed deploy/prd/v1.2.19 k8s/overlays/prd/kustomization.yaml | grep -qF '    newTag: v1.2.19'
  [ "$(jq -r .base "${STATE}/pr-create.json")" = "master" ]
  jq -r .body "${STATE}/pr-create.json" | grep -qF '**acc** runs it since #31 merged.'
  refute grep -q 'opens the same change for' <(jq -r .body "${STATE}/pr-create.json")
}

@test "the last overlay, an unknown overlay and a pull request that is not a deploy PR promote nothing" {
  merged_push deploy/prd/v1.2.19
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"is the last overlay"* ]]

  merged_push deploy/qa/v1.2.19
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"no overlay called 'qa'"* ]]

  merged_push feature/login
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a deploy PR"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a direct push to the overlays promotes nothing" {
  merged_push deploy/acc/v1.2.19
  echo '[]' >"${STATE}/commit-pulls.json"
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"came from no merged pull request"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "a merge that moved no managed image promotes nothing" {
  merged_push deploy/acc/v1.2.19
  cp "${STATE}/files@before-sha/k8s/overlays/acc/kustomization.yaml" "${STATE}/files@merge-sha/k8s/overlays/acc/kustomization.yaml"
  deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"without moving a tag in gitops-images"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

# ── Release candidates: gitops-prereleases-until ─────────────────────────────────────

# acc runs a candidate: every managed image at <tag> in the overlay at the base tip.
acc_runs() {
  sed "s/newTag: v1.2.18 #/newTag: $1 #/" "${STATE}/files/k8s/overlays/acc/kustomization.yaml" >"${WORK}/acc.yaml"
  mv "${WORK}/acc.yaml" "${STATE}/files/k8s/overlays/acc/kustomization.yaml"
}

# A merged acc deploy PR that moved the image to <tag>.
merged_acc_push() { # head-ref tag
  merged_push "$1"
  sed "s/newTag: v1.2.18/newTag: $2/" "${STATE}/files@before-sha/k8s/overlays/acc/kustomization.yaml" \
    >"${STATE}/files@merge-sha/k8s/overlays/acc/kustomization.yaml"
}

@test "until: a candidate's deploy PR for acc says nothing about prd" {
  release_event v1.2.19-rc.1 true
  PRERELEASES=true PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19-rc.1' "${STATE}/writes.log"
  refute grep -q 'opens the same change for' <(jq -r .body "${STATE}/pr-create.json")
}

@test "until: a merged candidate stops at acc and opens nothing for prd" {
  merged_acc_push deploy/acc/v1.2.19-rc.1 v1.2.19-rc.1
  unset BASE
  PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"prereleases stop at acc"* ]]
  [ ! -f "${STATE}/writes.log" ]
}

@test "until: without it, a merged candidate still goes on to prd" {
  merged_acc_push deploy/acc/v1.2.19-rc.1 v1.2.19-rc.1
  unset BASE
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/prd/v1.2.19-rc.1' "${STATE}/writes.log"
}

@test "until: a stable release whose candidate acc runs goes straight to prd" {
  acc_runs v1.2.19-rc.2
  release_event v1.2.19 false
  PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/prd/v1.2.19' "${STATE}/writes.log"
  refute grep -q 'deploy/acc/' "${STATE}/writes.log"
  committed deploy/prd/v1.2.19 k8s/overlays/prd/kustomization.yaml | grep -qF '    newTag: v1.2.19'
  jq -r .body "${STATE}/pr-create.json" | grep -qF '**acc** already runs its release candidate, so it goes straight to **prd**.'
}

@test "until: a stable release with no candidate in acc starts at acc" {
  release_event v1.2.19 false
  PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19' "${STATE}/writes.log"
  jq -r .body "${STATE}/pr-create.json" | grep -qF 'opens the same change for **prd**'
}

@test "until: a candidate of another version in acc does not count" {
  acc_runs v1.2.20-rc.1
  release_event v1.2.19 false
  PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ]
  refute grep -q 'deploy/prd/' "${STATE}/writes.log"
}

@test "until: a stable tag merged on acc still goes on to prd" {
  merged_acc_push deploy/acc/v1.2.19 v1.2.19
  unset BASE
  PRERELEASES_UNTIL=acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/prd/v1.2.19' "${STATE}/writes.log"
}

@test "until: the overlay is named or given as its path, must exist, and cannot be the last" {
  release_event v1.2.19 false
  PRERELEASES_UNTIL=k8s/overlays/acc deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  PRERELEASES_UNTIL=qa deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"'qa' is not one of gitops-overlays"* ]]

  PRERELEASES_UNTIL=other/acc deploy
  [ "$status" -eq 1 ]

  PRERELEASES_UNTIL=prd deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"is the last overlay"* ]]
}

@test "a candidate's own stable release is not a downgrade, and the candidate after it is" {
  acc_runs v1.2.19-rc.2
  release_event v1.2.19 false
  deploy
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx 'POST git/refs deploy/acc/v1.2.19' "${STATE}/writes.log"
  [ "$(output_value result)" = "created" ]

  rm -f "${STATE}/writes.log"
  acc_runs_stable() { sed 's/newTag: v1.2.19-rc.2 #/newTag: v1.2.19 #/' "${STATE}/files/k8s/overlays/acc/kustomization.yaml" >"${WORK}/a" && mv "${WORK}/a" "${STATE}/files/k8s/overlays/acc/kustomization.yaml"; }
  acc_runs_stable
  release_event v1.2.19-rc.3 true
  PRERELEASES=true deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"already runs a newer tag"* ]]
  [ ! -f "${STATE}/writes.log" ]
}
