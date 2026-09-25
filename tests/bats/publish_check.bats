#!/usr/bin/env bats
#
# The check run is what makes apply-before-merge enforceable, so the failure that matters is a
# required check that never reports: the pull request is then blocked forever, by nothing.

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export HEAD_SHA=0123456789abcdef0123456789abcdef01234567
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
prev=""
for arg in "$@"; do
  [ "$prev" = "--data" ] && printf '%s' "$arg" >"${WORK}/payload.json"
  prev="$arg"
done
exit "${CURL_EXIT:-0}"
STUBEOF
}

@test "a check run is published against the head commit" {
  CONCLUSION=success TITLE="Applied" SUMMARY="2 stacks" run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  grep -q 'repos/MagmaMoose/infra/check-runs' "$STUB_LOG"
  grep -q "\"head_sha\": *\"${HEAD_SHA}\"" "${WORK}/payload.json"
  grep -q '"conclusion": *"success"' "${WORK}/payload.json"
  grep -q '"status": *"completed"' "${WORK}/payload.json"
}

@test "action_required is a valid conclusion, because it is the one that blocks" {
  CONCLUSION=action_required run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  grep -q '"conclusion": *"action_required"' "${WORK}/payload.json"
}

@test "an invalid conclusion is refused rather than sent" {
  # GitHub rejects an unknown conclusion with a 422 the caller reports as a bare warning, so
  # the check silently never appears — the exact outcome this file exists to prevent.
  CONCLUSION=probably-fine run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "no head sha in scope is a no-op" {
  HEAD_SHA= run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "no token warns about the permission it needs" {
  AUTH_TOKEN= GITHUB_TOKEN= run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checks: write"* ]]
}

@test "an API failure warns rather than failing the job" {
  # The check run is how the result is REPORTED. Failing the job because the report did not post
  # makes the outcome less visible, not more.
  CURL_EXIT=22 run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "the details url is omitted when there is none, not sent empty" {
  DETAILS_URL= run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  refute grep -q '"details_url"' "${WORK}/payload.json"
}

@test "a title with quotes does not break the payload" {
  TITLE='2 stacks "failed" to apply' run bash "${SCRIPTS}/publish-check.sh"
  [ "$status" -eq 0 ]
  run jq -e . "${WORK}/payload.json"
  [ "$status" -eq 0 ]
}
