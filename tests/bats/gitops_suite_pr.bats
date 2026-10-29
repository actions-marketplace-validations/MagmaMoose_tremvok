#!/usr/bin/env bats
load helper

setup() {
  setup_common
  command -v yq >/dev/null || skip 'yq not installed'
  export GITHUB_REPOSITORY=acme/suite GITHUB_API_URL=https://api.example AUTH_TOKEN=ghs_test
  export OVERLAY=k8s/acc BASE=main BRANCH_PREFIX=chore/promote
  export EVENT_NAME=repository_dispatch ALLOW_DOWNGRADE=false
  export RELEASE_REPOSITORIES='{"ghcr.io/acme/app-a":"acme/app-a","ghcr.io/acme/app-b":"acme/app-b"}'
  export GITHUB_SERVER_URL=https://example
  export STATE="${WORK}/api"
  mkdir -p "$STATE"
  printf '[]' >"${STATE}/prs"
  printf 'base-sha' >"${STATE}/base-sha"
  cat >"${STATE}/base" <<'EOF'
resources:
  - ../../vendor/app
images:
  - name: ghcr.io/acme/app-a
    newTag: v1.0.0 # keep this marker
  - name: ghcr.io/acme/app-b
    newTag: v2.0.0
EOF
  export IMAGES='{"ghcr.io/acme/app-a":"v1.1.0"}'
  stub_script curl <<'STUB'
#!/usr/bin/env bash
method=GET url='' data='' out=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --write-out|--header|--retry|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#"${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/"}"
printf '%s %s\n' "$method" "$path" >>"$STUB_LOG"
status=200 body='{}'
if [[ -f "${STATE}/fail" && "${method} ${path}" == $(cat "${STATE}/fail")* ]]; then
  status=503
else
  case "${method} ${path}" in
    'GET git/ref/heads/main') body="{\"object\":{\"sha\":\"$(cat "${STATE}/base-sha")\"}}" ;;
    'GET git/ref/heads/chore/promote/acc')
      if [[ -f "${STATE}/pending" ]]; then body='{"object":{"sha":"pending-sha"}}'; else status=404; fi ;;
    'GET contents/'*)
      ref="${path##*ref=}"
      if [[ "$ref" == base* ]]; then f="${STATE}/base"; else f="${STATE}/pending"; fi
      if [[ ! -f "$f" ]]; then status=404
      else
        content="$(base64 <"$f" | tr -d '\n')"
        if [[ -f "${STATE}/corrupt" && "$ref" == chore/promote/acc ]]; then content="$(printf 'bad\n' | base64 | tr -d '\n')"; fi
        body="{\"sha\":\"blob-${ref}\",\"content\":\"${content}\"}"
      fi ;;
    'GET pulls?'*)
      if [[ -f "${STATE}/paginate" && "$path" == *page=1 ]]; then
        body="$(jq -n '[range(100) | {number:.,head:{ref:"other",repo:{full_name:"acme/suite"}}}]')"
      else body="$(cat "${STATE}/prs")"; fi ;;
    'POST git/refs') cp "${STATE}/base" "${STATE}/pending" ;;
    'DELETE git/refs/heads/chore/promote/acc') rm -f "${STATE}/pending"; status=204 ;;
    'POST merges')
      cp "$data" "${STATE}/merge-request"
      if [[ -f "${STATE}/conflict" ]]; then status=409
      elif [[ -f "${STATE}/merge-base" ]]; then
        cat "${STATE}/merge-base" >>"${STATE}/pending"
      else status=204; fi ;;
    'PUT contents/'*)
      cp "$data" "${STATE}/put-request"
      jq -r .content "$data" | base64 --decode >"${STATE}/pending"; status=201 ;;
    'POST pulls')
      jq --arg repo "$GITHUB_REPOSITORY" '[{number:42,html_url:"https://example/acme/suite/pull/42",body:.body,head:{ref:.head,repo:{full_name:$repo}}}]' "$data" >"${STATE}/prs"
      body='{"number":42,"html_url":"https://example/acme/suite/pull/42"}'; status=201 ;;
    'PATCH pulls/'*)
      jq --slurpfile patch "$data" '.[0].body=$patch[0].body' "${STATE}/prs" >"${STATE}/updated-prs"
      mv "${STATE}/updated-prs" "${STATE}/prs"
      body='{"number":42,"html_url":"https://example/acme/suite/pull/42"}' ;;
    *) printf 'unexpected API call: %s %s\n' "$method" "$path" >&2; status=599 ;;
  esac
fi
[[ -z "$out" ]] || printf '%s' "$body" >"$out"
printf '%s' "$status"
STUB
}
deploy() { run bash "${SCRIPTS}/gitops-suite-pr.sh"; }
tag() { GITOPS_IMAGE="$1" yq '(.images // [])[] | select(.name == strenv(GITOPS_IMAGE)) | .newTag' "${STATE}/pending"; }

@test 'sequential newer app releases refresh the same PR and retain other pending apps with current release links' {
  deploy
  [[ "$status" -eq 0 ]]
  [[ "$(output_value result)" == created ]]
  IMAGES='{"ghcr.io/acme/app-a":"v1.2.0"}' deploy
  [[ "$status" -eq 0 ]]
  IMAGES='{"ghcr.io/acme/app-b":"v2.1.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag ghcr.io/acme/app-a)" == v1.2.0 ]]
  [[ "$(tag ghcr.io/acme/app-b)" == v2.1.0 ]]
  [[ "$(grep -c '^POST pulls$' "$STUB_LOG")" -eq 1 ]]
  body="$(jq -r '.[0].body' "${STATE}/prs")"
  [[ "$body" == *'| `ghcr.io/acme/app-a` | `v1.0.0` | `v1.2.0` |'* ]]
  [[ "$body" == *'https://example/acme/app-a/releases/tag/v1.2.0'* ]]
  [[ "$body" == *'https://example/acme/app-b/releases/tag/v2.1.0'* ]]
  [[ "$body" != *'/releases/tag/v1.1.0'* ]]
  grep -q '# keep this marker' "${STATE}/pending"
  refute grep -q '^DELETE ' "$STUB_LOG"
  [[ "$(jq -r .head "${STATE}/merge-request")" == base-sha ]]
  [[ "$(jq -r .base "${STATE}/merge-request")" == chore/promote/acc ]]
}

@test 'a stale one-image event cannot discard its newer pending tag or block a newer second image' {
  deploy
  [[ "$status" -eq 0 ]]
  IMAGES='{"ghcr.io/acme/app-a":"v1.0.1","ghcr.io/acme/app-b":"v2.2.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag ghcr.io/acme/app-a)" == v1.1.0 ]]
  [[ "$(tag ghcr.io/acme/app-b)" == v2.2.0 ]]
  [[ "$output" == *'skipped stale v1.0.1'* ]]
  body="$(jq -r '.[0].body' "${STATE}/prs")"
  [[ "$body" == *'https://example/acme/app-a/releases/tag/v1.1.0'* ]]
  [[ "$body" != *'/releases/tag/v1.0.1'* ]]
}

@test 'base evolves through a merge without resetting or losing pending app changes' {
  deploy
  [[ "$status" -eq 0 ]]
  printf 'base-sha-2' >"${STATE}/base-sha"
  printf '\n# another merged base change\n' >>"${STATE}/base"
  printf '\n# another merged base change\n' >"${STATE}/merge-base"
  IMAGES='{"ghcr.io/acme/app-b":"v2.1.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag ghcr.io/acme/app-a)" == v1.1.0 ]]
  grep -q 'another merged base change' "${STATE}/pending"
  [[ "$(jq -r .head "${STATE}/merge-request")" == base-sha-2 ]]
  refute grep -q '^PATCH git/refs' "$STUB_LOG"
}

@test 'a base merge conflict fails before changing image tags or refreshing the PR' {
  deploy
  [[ "$status" -eq 0 ]]
  touch "${STATE}/conflict"
  : >"$STUB_LOG"
  IMAGES='{"ghcr.io/acme/app-b":"v2.1.0"}' deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'HTTP 409'* ]]
  refute grep -q '^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
  [[ "$(tag ghcr.io/acme/app-b)" == v2.0.0 ]]
}

@test 'malicious tags and malformed image mappings fail before the API' {
  IMAGES='{"ghcr.io/acme/app-a":"v1.1.0;touch /tmp/unwanted"}' deploy
  [[ "$status" -ne 0 ]]
  [[ ! -s "$STUB_LOG" ]]
  IMAGES='{"ghcr.io/acme/app-a":42}' deploy
  [[ "$status" -ne 0 ]]
  [[ ! -s "$STUB_LOG" ]]
}

@test 'an unknown image fails instead of silently skipping the requested version' {
  IMAGES='{"ghcr.io/acme/missing":"v1.1.0"}' deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'expected exactly one images entry'* ]]
  refute grep -q '^POST\|^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
}

@test 'release repository mapping is validated before the API' {
  RELEASE_REPOSITORIES='{"ghcr.io/acme/app-a":"https://example/acme/app-a"}' deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'owner/repository names'* ]]
  [[ ! -s "$STUB_LOG" ]]
}

@test 'registry image names with a port are supported without changing unrelated entries' {
  sed 's#ghcr.io/acme/app-a#registry.example:5000/acme/app-a#' "${STATE}/base" >"${STATE}/port-base"
  mv "${STATE}/port-base" "${STATE}/base"
  IMAGES='{"registry.example:5000/acme/app-a":"v1.1.0"}' RELEASE_REPOSITORIES='{}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag registry.example:5000/acme/app-a)" == v1.1.0 ]]
  [[ "$(tag ghcr.io/acme/app-b)" == v2.0.0 ]]
}

@test 'manual dispatch fails closed without an allowlist and guards the rerun actor' {
  EVENT_NAME=workflow_dispatch GITHUB_ACTOR=alice GITHUB_TRIGGERING_ACTOR=alice deploy
  [[ "$status" -ne 0 ]]
  [[ ! -s "$STUB_LOG" ]]
  EVENT_NAME=workflow_dispatch ALLOWED_ACTORS=alice GITHUB_ACTOR=alice GITHUB_TRIGGERING_ACTOR=mallory deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'mallory is not an allowed'* ]]
  [[ ! -s "$STUB_LOG" ]]
  EVENT_NAME=workflow_dispatch ALLOWED_ACTORS=alice GITHUB_ACTOR=alice GITHUB_TRIGGERING_ACTOR='' deploy
  [[ "$status" -ne 0 ]]
  [[ ! -s "$STUB_LOG" ]]
}

@test 'manual downgrade requires an explicit flag and both authorised actors' {
  deploy
  [[ "$status" -eq 0 ]]
  EVENT_NAME=workflow_dispatch ALLOWED_ACTORS='Alice,bob' GITHUB_ACTOR=alice GITHUB_TRIGGERING_ACTOR=Bob IMAGES='{"ghcr.io/acme/app-a":"v0.9.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag ghcr.io/acme/app-a)" == v1.1.0 ]]
  EVENT_NAME=workflow_dispatch ALLOWED_ACTORS='Alice,bob' GITHUB_ACTOR=alice GITHUB_TRIGGERING_ACTOR=Bob ALLOW_DOWNGRADE=true IMAGES='{"ghcr.io/acme/app-a":"v0.9.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(tag ghcr.io/acme/app-a)" == v0.9.0 ]]
  ALLOW_DOWNGRADE=true deploy
  [[ "$status" -ne 0 ]]
}

@test 'an API outage while finding the PR fails closed without mutation' {
  printf 'GET pulls?' >"${STATE}/fail"
  deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'HTTP 503'* ]]
  refute grep -q '^POST\|^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
}

@test 'PR pagination finds and refreshes the existing promotion PR on a later page' {
  deploy
  [[ "$status" -eq 0 ]]
  touch "${STATE}/paginate"
  IMAGES='{"ghcr.io/acme/app-a":"v1.2.0"}' deploy
  [[ "$status" -eq 0 ]]
  grep -q 'page=2' "$STUB_LOG"
  [[ "$(grep -c '^POST pulls$' "$STUB_LOG")" -eq 1 ]]
}

@test 'multiple same-environment promotion PRs fail before mutation' {
  deploy
  [[ "$status" -eq 0 ]]
  jq '. + [.[0] | .number=43]' "${STATE}/prs" >"${STATE}/duplicate"
  mv "${STATE}/duplicate" "${STATE}/prs"
  : >"$STUB_LOG"
  deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'multiple promotion PRs'* ]]
  refute grep -q '^POST\|^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
}

@test 'readback proof refuses to open a PR when the selected images were not retained' {
  touch "${STATE}/corrupt"
  deploy
  [[ "$status" -ne 0 ]]
  [[ "$output" == *'did not retain the selected images'* ]]
  refute grep -q '^POST pulls$' "$STUB_LOG"
}

@test 'a no-op without an open PR performs no writes and a dry run performs no writes' {
  IMAGES='{"ghcr.io/acme/app-a":"v1.0.0"}' deploy
  [[ "$status" -eq 0 ]]
  [[ "$(output_value result)" == unchanged ]]
  refute grep -q '^POST\|^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
  DRY_RUN=true deploy
  [[ "$status" -eq 0 ]]
  [[ "$(output_value result)" == planned ]]
  refute grep -q '^POST\|^PUT\|^PATCH\|^DELETE' "$STUB_LOG"
}
