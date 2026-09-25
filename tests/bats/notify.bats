#!/usr/bin/env bats

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=MagmaMoose/website
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
}

# ── webhooks ─────────────────────────────────────────────────────────────────────────────

@test "no sinks configured is a no-op" {
  run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a Slack outage never fails the deploy" {
  # The rule: a deploy that worked and a chat message that did not is a successful deploy.
  # Failing here invites a re-run, and a re-run deploys again to fix a notification.
  stub curl 22 ''
  SLACK_WEBHOOK=https://hooks.slack.test/x run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"Slack notification failed"* ]]
}

@test "both sinks fire when both are configured" {
  stub curl 0 '200'
  SLACK_WEBHOOK=https://hooks.slack.test/x TEAMS_WEBHOOK=https://outlook.test/y \
    run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 2 ]
}

@test "notify=on-success stays quiet about a failure" {
  stub curl 0 '200'
  NOTIFY=on-success STATUS=failure SLACK_WEBHOOK=https://hooks.slack.test/x \
    run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "notify=on-failure reports a rollback" {
  stub curl 0 '200'
  NOTIFY=on-failure STATUS=rolled-back SLACK_WEBHOOK=https://hooks.slack.test/x \
    run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$(grep -c '^curl' "$STUB_LOG")" -eq 1 ]
}

@test "a version containing a quote does not break the payload" {
  # `jq --arg` rather than interpolation: an unescaped quote would produce a 400 that the
  # failure isolation reports as an unexplained "notification failed".
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [ "$prev" = "--data" ]; then printf '%s' "$arg" >"${WORK}/payload.json"; fi
  prev="$arg"
done
printf '200'
STUBEOF
  SLACK_WEBHOOK=https://hooks.slack.test/x VERSION='1.0.0 "beta" <script>' \
    REPOSITORY=MagmaMoose/website ENVIRONMENT=prod run bash "${SCRIPTS}/notify-webhook.sh"
  [ "$status" -eq 0 ]
  run jq -e . "${WORK}/payload.json"
  [ "$status" -eq 0 ]
}

# ── sticky pull-request comment ──────────────────────────────────────────────────────────

@test "with no pull request in scope nothing is posted" {
  run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "the first run posts a new comment" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"--request PATCH"*) printf '{}' ;;
  *"--request POST"*) printf '{"id":1}' ;;
  *) printf '[]' ;;
esac
STUBEOF
  PR_NUMBER=42 BODY="hello" run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--request POST" "$STUB_LOG"
  refute grep -q -- "--request PATCH" "$STUB_LOG"
}

@test "a second run edits the existing comment in place" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"--request PATCH"*) printf '{}' ;;
  *) printf '%s' '[{"id":99,"body":"<!-- tremvok:deploy --> old"}]' ;;
esac
STUBEOF
  PR_NUMBER=42 BODY="new" run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  grep -q "issues/comments/99" "$STUB_LOG"
  refute grep -q -- "--request POST" "$STUB_LOG"
}

@test "different comment keys do not collide" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"--request POST"*) printf '{"id":2}' ;;
  *) printf '%s' '[{"id":99,"body":"<!-- tremvok:terragrunt --> plan"}]' ;;
esac
STUBEOF
  PR_NUMBER=42 COMMENT_KEY=deploy BODY="preview" run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--request POST" "$STUB_LOG"
}

@test "a missing token warns instead of failing the deploy" {
  AUTH_TOKEN= GITHUB_TOKEN= PR_NUMBER=42 BODY=x run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull-requests: write"* ]]
}

@test "an API failure warns instead of failing the deploy" {
  stub curl 1 ''
  PR_NUMBER=42 BODY=x run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

# A 200 KB body: GitHub's limit is 65,536 characters, and a single argument is capped at 128 KiB.
# Handed over as BODY_FILE, the way deploy-terragrunt.sh hands over a plan. Linux caps any one
# environment string at 128 KiB too (MAX_ARG_STRLEN), so BODY=<200 KB> fails execve with E2BIG
# before notify-pr.sh runs: the test passed on macOS, which has no per-string cap, and failed CI.
@test "an oversized body is sent from a file and cut to fit" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
prev=""
for arg in "$@"; do
  if [ "$prev" = "--data-binary" ]; then cp "${arg#@}" "${WORK}/request.json"; fi
  prev="$arg"
done
case "$*" in
  *"--request POST"*) printf '{"id":1}' ;;
  *) printf '[]' ;;
esac
STUBEOF
  printf '%200000s' | tr ' ' x >"${WORK}/body.md"
  BODY_FILE="${WORK}/body.md" PR_NUMBER=42 run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--request POST" "$STUB_LOG"
  # No argument carried the body.
  [ "$(awk '{ print length }' "$STUB_LOG" | sort -n | tail -1)" -lt 2000 ]
  [ "$(jq -r '.body | length' "${WORK}/request.json")" -le 65000 ]
  jq -r '.body' "${WORK}/request.json" | grep -q "Cut short to fit GitHub's comment size limit"
}

@test "a refused post is a warning, not a false success" {
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  *"--request POST"*) exit 22 ;;
  *) printf '[]' ;;
esac
STUBEOF
  PR_NUMBER=42 BODY=hello run bash "${SCRIPTS}/notify-pr.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not post the pull-request comment"* ]]
  [[ "$output" != *"posted a new pull-request comment"* ]]
}
