#!/usr/bin/env bats
#
# `terragrunt-pull-request` points a manual run at a named pull request. One override drives
# all three consumers — the approval gate, the plan comment and the check run — so the failure
# to prevent is any of them drifting onto a different pull request, or onto a commit no merge
# button is waiting on.

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p terraform/aws/prod/api
  touch terraform/terragrunt.hcl terraform/aws/prod/api/terragrunt.hcl

  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export ROOT_DIR=terraform
  export WORK_DIR="${WORK}/tg"
  export HEAD_SHA=shafromevent
  export GITHUB_SHA=shafromevent
  export EVENT_NAME=workflow_dispatch
  export APPROVERS='[]'

  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
  init) exit 0 ;;
  plan) printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n'; exit "${PLAN_EXIT:-2}" ;;
  apply) printf 'Apply complete.\n'; exit "${APPLY_EXIT:-0}" ;;
esac
exit 0
STUBEOF

  # The /pulls/{n} body answers both callers: terragrunt-pr-head.sh wants .head, and
  # approval-gate.sh wants .user.login.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
# Two-line defaults, never `${X:-{...}}`: brace expansion closes at the FIRST `}`, so an
# inline JSON default silently loses most of itself.
PR_FILES="${PR_FILES:-}"
[ -n "$PR_FILES" ] || PR_FILES='[{"filename":"terraform/aws/prod/api/main.tf"}]'
PR_JSON="${PR_JSON:-}"
[ -n "$PR_JSON" ] || PR_JSON='{"user":{"login":"author"},"head":{"sha":"shafromapi1234","repo":{"fork":false}}}'
case "$*" in
  *"/files?"*) printf '%s' "$PR_FILES" ;;
  *"/reviews?"*)
    case "$*" in *"page=1"*) printf '%s' "$APPROVERS" ;; *) printf '[]' ;; esac ;;
  *"/check-runs"*) printf '{"id":1}' ;;
  *"/comments"*) printf '[]' ;;
  *"/pulls/"*) printf '%s' "$PR_JSON"; exit "${PR_EXIT:-0}" ;;
  *) printf '{}' ;;
esac
STUBEOF
}

@test "a non-numeric terragrunt-pull-request is refused with no API call at all, so a typo can never become a request for an attacker-chosen path segment" {
  TG_PULL_REQUEST='1234/../../secrets' run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"terragrunt-pull-request: '1234/../../secrets' is not a pull-request number. Digits only, e.g. 1234."* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "an empty terragrunt-pull-request is refused too, rather than building /pulls//files" {
  run bash "${SCRIPTS}/terragrunt-pr-head.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a pull-request number"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "the override beats the event number, so a manual run cannot gate on one pull request and comment on another" {
  PR_NUMBER=7 TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  grep -q '/pulls/1234/files' "$STUB_LOG"
  grep -q '/pulls/1234/reviews' "$STUB_LOG"
  grep -q '/issues/1234/comments' "$STUB_LOG"
  refute grep -q '/pulls/7/' "$STUB_LOG"
  refute grep -q '/issues/7/' "$STUB_LOG"
}

@test "the check run is published against the fetched head sha, so an action_required check cannot land on a default-branch commit no pull request contains" {
  TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  grep -q 'shafromapi1234' "$STUB_LOG"
  refute grep -q '"head_sha": "shafromevent"' "$STUB_LOG"
}

@test "a pull request this run cannot read ends it before terragrunt is invoked, so a wrong number is never a plan-only run with no check and no explanation" {
  PR_EXIT=22 TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read pull request #1234"* ]]
  refute grep -q 'terragrunt plan' "$STUB_LOG"
  refute grep -q 'check-runs' "$STUB_LOG"
}

@test "a pull request with no head commit is refused, because a check run has to land somewhere" {
  PR_JSON='{"user":{"login":"author"},"head":{"repo":{"fork":false}}}' TG_PULL_REQUEST=1234 \
    run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no head commit"* ]]
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "a fork pull request named by hand is refused, so the manual path cannot aim a deploy credential at fork code the automatic path already refuses" {
  PR_JSON='{"user":{"login":"author"},"head":{"sha":"forksha","repo":{"fork":true}}}' \
    TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"comes from a fork"* ]]
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "a head sha that is not in the checked-out tree warns and continues, so forgetting ref: is visible rather than a silently wrong plan" {
  TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not contain #1234's head commit"* ]]
  [[ "$output" == *"refs/pull/1234/merge"* ]]
  # A warning and not a failure: `checkout: false` with a partial tree is a legitimate choice.
  grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "an empty override leaves the event path untouched, so no existing run changes behaviour" {
  PR_NUMBER=7 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  grep -q '/pulls/7/files' "$STUB_LOG"
  # No head fetch: the event already carried the sha, and the check run is published against
  # it. Asserted on the override's own log line and on the sha that reached the check run,
  # NOT on the request URL: approval-gate.sh fetches the same `/pulls/7` to find the author,
  # so `/pulls/7` is in the log either way and an assertion on it proves nothing. It was
  # written as one, and it was wrong — it only ever passed because a negated assertion in the
  # middle of a test body is exempt from errexit and cannot fail.
  [[ "$output" != *"terragrunt-pull-request=#"* ]]
  grep -q '"head_sha": "shafromevent"' "$STUB_LOG"
  refute grep -q 'shafromapi1234' "$STUB_LOG"
}

@test "the override plus terragrunt-apply: force applies, so a named pull request is a full path and not a plan-only curiosity" {
  # `force` and not a standing approval. A manual run is not an approval: nobody re-approved
  # this commit by dispatching the workflow, and applying on an approval the run merely
  # observed is how a commit pushed after that approval gets applied unreviewed. The manual
  # apply has its own authorisation, `terragrunt-apply-operators`, and this is it.
  export APPROVERS='[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
  APPLY=force GITHUB_ACTOR=operator APPLY_OPERATORS=operator TG_PULL_REQUEST=1234 \
    run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  grep -q 'terragrunt apply' "$STUB_LOG"
  # And the apply is still aimed at the named pull request, not at the event's.
  grep -q '/issues/1234/comments' "$STUB_LOG"
}

@test "the override plus an approval nobody re-gave plans and reports, so a manual run cannot spend an approval left on an earlier commit" {
  export APPROVERS='[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
  TG_PULL_REQUEST=1234 run bash "${SCRIPTS}/terragrunt-changed-files.sh"
  [ "$status" -eq 0 ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  grep -q 'Approved, but not applied for this commit' "$STUB_LOG"
}
