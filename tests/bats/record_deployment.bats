#!/usr/bin/env bats
#
# The record step is failure-isolated by design: a deployment history that missed an entry is a
# gap in a report, while a deploy failed by its own bookkeeping is an outage. Every path below
# therefore exits 0 — which is exactly why it needs tests, since a script that never fails
# looks identical to one that never runs.

load helper

setup() {
  setup_common
  export API_URL=https://tremvok.test
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.test/?foo=bar'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  export GITHUB_RUN_ID=777
  export GITHUB_RUN_ATTEMPT=2
  export ENVIRONMENT=production
  export MODE=deploy
  export TARGET=s3-cloudfront
  export STATUS=success

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"audience="*)
    printf '{"value":"%s"}' "${OIDC_TOKEN-header.payload.signature}" ;;
  *)
    prev=""
    for arg in "$@"; do
      [ "$prev" = "--data" ] && printf '%s' "$arg" >"${WORK}/payload.json"
      prev="$arg"
    done
    printf '{"deployment_id":"dep-1","duplicate":false}\n%s' "${HTTP_CODE:-200}" ;;
esac
STUBEOF
}

@test "no api-url means nothing is recorded and nothing fails" {
  API_URL= run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a missing id-token permission warns and does not fail the deploy" {
  ACTIONS_ID_TOKEN_REQUEST_URL= run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"id-token: write"* ]]
  [[ "$output" == *"::warning::"* ]]
}

@test "a successful record reports its id" {
  run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value record-id)" = "dep-1" ]
}

@test "the token is minted for the configured audience and sent as a bearer" {
  API_AUDIENCE=tremvok run bash "${SCRIPTS}/record-deployment.sh"
  grep -q 'audience=tremvok' "$STUB_LOG"
  grep -q 'authorization: Bearer header.payload.signature' "$STUB_LOG"
}

@test "the delivery id makes a retried step a duplicate and a re-run a new deployment" {
  # run_id + attempt is the line between "the same deployment, reported twice" and "a second
  # deployment". Getting it wrong either double-pings Slack or hides a real redeploy.
  run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  grep -q '"delivery_id": *"777:2:production:deploy"' "${WORK}/payload.json"
}

@test "the body carries no repository field, because the server takes it from the token" {
  run bash "${SCRIPTS}/record-deployment.sh"
  refute grep -q '"repository"' "${WORK}/payload.json"
}

@test "empty optional fields are omitted rather than sent as empty strings" {
  # The API validates url as an http(s) URL, so an empty string is a 422 where an absent field
  # is simply "this target does not produce one".
  URL= VERSION= run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  refute grep -q '"url"' "${WORK}/payload.json"
  refute grep -q '"version"' "${WORK}/payload.json"
}

@test "verified is sent as a JSON boolean, not a string" {
  VERIFIED=true run bash "${SCRIPTS}/record-deployment.sh"
  grep -q '"verified": *true' "${WORK}/payload.json"
  VERIFIED=false run bash "${SCRIPTS}/record-deployment.sh"
  grep -q '"verified": *false' "${WORK}/payload.json"
}

@test "an API error warns and leaves the deploy successful" {
  HTTP_CODE=403 run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"403"* ]]
  [ -z "$(output_value record-id)" ]
}

@test "a failure to mint a token warns and does not fail the deploy" {
  OIDC_TOKEN= run bash "${SCRIPTS}/record-deployment.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}
