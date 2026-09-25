#!/usr/bin/env bats
#
# The failure this guards: terragrunt buffers plan output to a file, so an endpoint the runner
# cannot reach is not an error, it is fifteen minutes of an empty log until the timeout. These
# tests hold the line between "no answer at all", which fails, and "an answer I did not like",
# which does not.

load helper

setup() {
  setup_common
  cd "$WORK"

  # Behaviour by URL: anything with `down` in it is a connect timeout, the egress lookup is
  # separate, everything else answers PROBE_OUT.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
case "$url" in
  *ipify*) printf '%s' "${EGRESS_OUT:-203.0.113.7}"; exit "${EGRESS_EXIT:-0}" ;;
  *down*)  printf '000 8.001'; exit 28 ;;
  *)       printf '%s' "${PROBE_OUT:-200 0.021}"; exit "${PROBE_EXIT:-0}" ;;
esac
STUBEOF
}

@test "an unreachable endpoint fails the step, so the plan never starts and the run does not sit silent until the timeout" {
  PREFLIGHT_URLS='https://down.example.com/state' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNREACHABLE"* ]]
  [[ "$output" == *"curl exit 28"* ]]
  [[ "$output" == *"1 of 1 preflight endpoints are unreachable"* ]]
}

@test "a 401 is reachable and passes, because an unauthenticated probe of a credentialed endpoint is supposed to be refused" {
  PROBE_OUT='401 0.030' PREFLIGHT_URLS='https://state.example.com/?comp=list' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"not proof the credential works"* ]]
}

@test "a 403 passes for the same reason a 401 does, so a locked-down endpoint is not read as a broken network" {
  PROBE_OUT='403 0.030' PREFLIGHT_URLS='https://state.example.com/?comp=list' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
}

@test "a 404 passes: the path may be wrong, the network is not" {
  PROBE_OUT='404 0.030' PREFLIGHT_URLS='https://api.example.com/nope' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"The path may be wrong, the network is not"* ]]
}

@test "a 5xx warns and passes, so a transient 503 cannot turn this into a flaky guard that gets deleted" {
  PROBE_OUT='503 0.030' PREFLIGHT_URLS='https://api.example.com/versions' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "an empty input probes nothing and exits 0, so every existing caller is unaffected" {
  PREFLIGHT_URLS='' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "blank lines and # comments are ignored rather than probed as URLs" {
  PREFLIGHT_URLS=$'# the state backend\n\n  https://state.example.com/\n\nhttps://api.example.com/\n' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 2 ]
}

@test "a block scalar holding only comments probes nothing rather than failing on an empty list" {
  PREFLIGHT_URLS=$'# nothing yet\n' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "every endpoint is probed even when the first is unreachable, so one run names them all instead of one per attempt" {
  PREFLIGHT_URLS=$'https://down-a.example.com/\nhttps://up.example.com/\nhttps://down-b.example.com/' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [ "$(grep -c 'UNREACHABLE' <<<"$output")" -eq 2 ]
  [[ "$output" == *"2 of 3 preflight endpoints are unreachable"* ]]
  [[ "$output" == *"down-b.example.com"* ]]
}

@test "the probe does not retry, because a retry loop is the multi-minute wait this check exists to replace" {
  PREFLIGHT_URLS='https://down.example.com/' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  # On curl's own argv, not on how many times the stub ran. `--retry` retries INSIDE one
  # invocation, so counting invocations passes whether or not the flag is there and cannot
  # observe the mutation this test is named for. `--retry-all-errors` too: on its own it
  # does nothing, but with --retry it is what turns a connection refusal — the exact shape
  # this check is here to catch in eight seconds — into a retried wait.
  probe="$(grep 'down.example.com' "$STUB_LOG")"
  [[ "$probe" != *"--retry"* ]]
  # And the loop still probes each endpoint once, so a retry cannot arrive as a second call
  # from this script either.
  [ "$(grep -c 'down.example.com' "$STUB_LOG")" -eq 1 ]
}

@test "the probe is bounded, so a hanging endpoint cannot become the hang this check catches" {
  PREFLIGHT_URLS='https://state.example.com/' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--max-time 8' "$STUB_LOG"
}

@test "PROBE_TIMEOUT=0 is refused, because curl --max-time 0 is unlimited and reintroduces the hang" {
  PROBE_TIMEOUT=0 PREFLIGHT_URLS='https://state.example.com/' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlimited"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "a non-numeric PROBE_TIMEOUT is refused rather than passed to curl" {
  PROBE_TIMEOUT=8s PREFLIGHT_URLS='https://state.example.com/' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "a line that is not an http(s) URL is refused before any request, because curl would guess a scheme and probe something else" {
  PREFLIGHT_URLS=$'# the state backend\nstate.example.com' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  # Named by index and by what is wrong with it. The line itself is not echoed: a line in the
  # wrong input is exactly the line most likely to be a secret pasted somewhere it does not go.
  [[ "$output" == *"line 2 is not an http(s) URL"* ]]
  [[ "$output" == *"no scheme at all"* ]]
  [[ "$output" != *"state.example.com"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "the password in a credential-bearing preflight URL never reaches the log or the step summary, because the guard that refuses it must not be the thing that publishes it" {
  # secretlint-disable-next-line @secretlint/secretlint-rule-basicauth
  PREFLIGHT_URLS=$'https://state.example.com/ok\nhttps://user:FAKEPWD123@state.example.com/' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"FAKEPWD123"* ]]
  refute grep -q 'FAKEPWD123' "$GITHUB_STEP_SUMMARY"
  refute grep -q 'FAKEPWD123' "$STUB_LOG"
  # Still useful: the line index, and the URL with its userinfo replaced.
  [[ "$output" == *"line 2 carries credentials in the URL"* ]]
  [[ "$output" == *"https://<redacted>@state.example.com/"* ]]
}

@test "a URL carrying userinfo is refused, because a probe URL is printed into a run log that is public on a public repository" {
  # secretlint-disable-next-line @secretlint/secretlint-rule-basicauth
  PREFLIGHT_URLS='https://user:FAKETKN456@state.example.com/' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credentials in the URL"* ]]
  [[ "$output" != *"FAKETKN456"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "the egress IP is printed only when something is unreachable, so a clean run makes no third-party call the caller did not ask for" {
  PREFLIGHT_URLS='https://state.example.com/' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"runner egress IP"* ]]
  refute grep -q 'ipify' "$STUB_LOG"

  PREFLIGHT_URLS='https://down.example.com/' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runner egress IP: 203.0.113.7"* ]]
}

@test "a failing egress lookup prints unknown and cannot change the exit status, because a diagnostic must not decide the result" {
  EGRESS_EXIT=6 PREFLIGHT_URLS='https://down.example.com/' \
    run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"runner egress IP: unknown"* ]]
}

@test "the unreachable endpoints are named on the step summary, not only in the log" {
  PREFLIGHT_URLS='https://down.example.com/state' run bash "${SCRIPTS}/preflight-urls.sh"
  [ "$status" -ne 0 ]
  grep -q 'an endpoint is unreachable' "$GITHUB_STEP_SUMMARY"
  grep -q 'down.example.com/state' "$GITHUB_STEP_SUMMARY"
}
