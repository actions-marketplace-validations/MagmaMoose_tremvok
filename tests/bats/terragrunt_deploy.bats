#!/usr/bin/env bats

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p terraform/aws/prod/api
  touch terraform/terragrunt.hcl terraform/aws/prod/api/terragrunt.hcl
  printf 'terraform/aws/prod/api/main.tf\n' >changed.txt

  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export ROOT_DIR=terraform
  export SCOPE=changed
  export CHANGED_FILES="${WORK}/changed.txt"
  export WORK_DIR="${WORK}/tg"
  export HEAD_SHA=abc123
  export APPROVERS='[]'

  # `terragrunt` whose plan exit code is the interesting variable: 0 no changes, 2 changes,
  # anything else an error. That is the contract `-detailed-exitcode` gives.
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s (cwd=%s)\n' "$*" "${PWD##*/}" >>"${STUB_LOG}"
printf '%s ARM_ACCESS_KEY=%s\n' "$1" "${ARM_ACCESS_KEY:-<unset>}" >>"${STUB_LOG}.env"
case "$1" in
  init) exit 0 ;;
  plan) printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n'; exit "${PLAN_EXIT:-2}" ;;
  apply) printf 'Apply complete.\n'; exit "${APPLY_EXIT:-0}" ;;
esac
exit 0
STUBEOF

  # GitHub: reviews come from $APPROVERS, the commit-to-pull-request lookup from
  # $MERGED_PULLS, everything else is accepted. Each has its own exit code so an outage can be
  # told apart from an empty answer, which is the distinction the push path rests on.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"/commits/"*"/pulls"*)
    printf '%s' "${MERGED_PULLS:-[]}"; exit "${MERGED_PULLS_EXIT:-0}" ;;
  *"/reviews?"*)
    case "$*" in *"page=1"*) printf '%s' "$APPROVERS" ;; *) printf '[]' ;; esac
    exit "${REVIEWS_EXIT:-0}" ;;
  *"/pulls/"*) printf '%s' '{"user":{"login":"author"}}' ;;
  *"/check-runs"*) printf '{"id":1}' ;;
  *"/comments"*) printf '%s' "${EXISTING_COMMENTS:-[]}" ;;
  *) printf '{}' ;;
esac
STUBEOF
}

merged() { export MERGED_PULLS='[{"number":123,"merged_at":"2026-08-18T10:00:00Z"}]'; }

approved() {
  export APPROVERS='[{"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-08-18T10:00:00Z"}]'
}

@test "no affected stacks still publishes the check, so a required check cannot block forever" {
  printf 'README.md\n' >changed.txt
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value stacks)" = "0" ]
  grep -q '"conclusion": *"success"' <<<"$(grep -o -- '--data .*' "$STUB_LOG" | head -1)" || \
    grep -q 'check-runs' "$STUB_LOG"
}

@test "a plan with changes and no approval does not apply" {
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value plan-changes)" = "1" ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "an approval event authorises the apply" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
  [ "$(output_value approvers)" = "@reviewer" ]
  grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a failed plan blocks the apply even with an approval" {
  approved
  PLAN_EXIT=1 PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value plan-failures)" = "1" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a clean plan needs no approval and applies nothing" {
  PLAN_EXIT=0 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value plan-changes)" = "0" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "apply=never plans and stops, approval or not" {
  approved
  APPLY=never PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
}

@test "a failing apply is reported and fails the run" {
  approved
  APPLY_EXIT=1 PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value apply-failures)" = "1" ]
}

@test "the plan comment carries the stack table and the gate" {
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'Terragrunt plan' "${WORK_DIR}/comment.md"
  grep -q 'aws/prod/api' "${WORK_DIR}/comment.md"
  grep -q 'Waiting for an independent approval' "${WORK_DIR}/comment.md"
}

@test "credential-shaped values are redacted before they reach the comment" {
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
  init) exit 0 ;;
  plan) printf 'client_secret = "hunter2"\nPlan: 1 to add, 0 to change, 0 to destroy.\n'; exit 2 ;;
esac
exit 0
STUBEOF
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  refute grep -q 'hunter2' "${WORK_DIR}/comment.md"
  grep -q 'client_secret = "\*\*\*"' "${WORK_DIR}/comment.md"
}

@test "a dry run plans nothing and applies nothing" {
  approved
  DRY_RUN=true PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^terragrunt' "$STUB_LOG"
}


# --- per-stack environment -----------------------------------------------------------------

@test "the matching pattern's credential reaches the stack, and the catch-all's does not" {
  # The case this exists for: production state in a separate account from everything else,
  # which is a deliberate blast-radius boundary. One credential cannot reach both.
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*  ARM_ACCESS_KEY=DEVKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
  refute grep -q 'ARM_ACCESS_KEY=DEVKEY' "${STUB_LOG}.env"
}

@test "a stack matching only the catch-all gets the catch-all's credential" {
  mkdir -p terraform/aws/acc/api
  touch terraform/aws/acc/api/terragrunt.hcl
  printf 'terraform/aws/acc/api/main.tf\n' >changed.txt
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*  ARM_ACCESS_KEY=DEVKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=DEVKEY' "${STUB_LOG}.env"
  refute grep -q 'ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "first match wins, so order is the contract and not an accident" {
  STACK_ENV=$'*  ARM_ACCESS_KEY=CATCHALL\n*/prod/*  ARM_ACCESS_KEY=PRDKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=CATCHALL' "${STUB_LOG}.env"
}

@test "the apply gets the same credential the plan did" {
  # A plan that read state with one credential and an apply that wrote it with another is
  # the worst version of this bug, because the plan looks fine.
  approved
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY' PR_NUMBER=42 \
    EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^apply ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "no stack-env means the environment is untouched" {
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=<unset>' "${STUB_LOG}.env"
}

@test "blank lines and comments are ignored rather than failing the run" {
  STACK_ENV=$'# production state lives elsewhere\n\n  */prod/*  ARM_ACCESS_KEY=PRDKEY\n' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q '^plan ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "several variables for one pattern all reach the stack" {
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=PRDKEY\n*/prod/*  ARM_SUBSCRIPTION_ID=sub-1' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'ARM_ACCESS_KEY=PRDKEY' "${STUB_LOG}.env"
}

@test "a line with a pattern but no assignment is refused rather than silently skipped" {
  STACK_ENV=$'*/prod/*' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no KEY=VALUE"* ]]
}

@test "a line that is not an assignment is refused" {
  STACK_ENV=$'*/prod/*  not-an-assignment' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not assign"* ]]
}

@test "a malformed stack-env line is refused by index, glob and KEY, and its VALUE never reaches the log or the step summary" {
  # terragrunt-stack-env exists to carry per-stack storage-account keys, so the value half of
  # any line is a credential. A guard that refuses a bad line by echoing it publishes the
  # credential into an ::error:: annotation, which is as public as the repository.
  STACK_ENV=$'*/prod/*  ARM_ACCESS_KEY=GOODKEY\n*/prod/*  1BAD=SUPERSECRETKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERSECRETKEY"* ]]
  refute grep -q 'SUPERSECRETKEY' "$GITHUB_STEP_SUMMARY"
  # And still enough to fix it: which line, which glob, which key.
  [[ "$output" == *"line 2"* ]]
  [[ "$output" == *"*/prod/*"* ]]
  [[ "$output" == *"1BAD"* ]]
}

@test "a stack-env line whose glob was forgotten does not print the value that lands in the glob slot, because that is the mistake somebody makes with a credential in hand" {
  # No whitespace on the line, so `KEY=VALUE` IS the glob as far as the parser is concerned.
  STACK_ENV=$'ARM_ACCESS_KEY=SUPERSECRETKEY' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERSECRETKEY"* ]]
  refute grep -q 'SUPERSECRETKEY' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"line 1"* ]]
  # Named by line number and NOTHING quoted from the slot. Cutting at the first `=` was the
  # earlier answer and it is not enough: a base64 state-backend key has no `=` until its `==`
  # padding, so "everything before the first =" is the whole key.
  [[ "$output" == *"not a glob"* ]]
}

@test "a wrapped base64 key alone in the glob slot is not printed, because cutting the slot at its first '=' would print all of it" {
  # The shape a YAML block scalar makes when a long value wraps onto its own line: no
  # whitespace, and no `=` until the padding at the very end.
  key='TestBase64KeyFixtureNoEqualsUntilPaddingAAAAAAAAAAAAAAAAAAAAAAAAAAAABB=='
  STACK_ENV="*/prod/*  ARM_ACCESS_KEY=
${key}" run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"TestBase64"* ]]
  refute grep -q 'TestBase64' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"line 2"* ]]
}

@test "a short secret with no '/' or '*' is not quoted as a glob, because a glob is a path pattern and a short password is indistinguishable from a short word" {
  STACK_ENV=$'hunter2pw' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"hunter2pw"* ]]
  refute grep -q 'hunter2pw' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"line 1"* ]]
}

@test "a stack-env line with no '=' at all is described rather than echoed, because a value whose KEY was mistyped is still a value" {
  STACK_ENV=$'*/prod/*  SUPERSECRETKEY' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERSECRETKEY"* ]]
  refute grep -q 'SUPERSECRETKEY' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"no '=' in it at all"* ]]
}

@test "the index counts blank and commented lines, so it names the line the caller typed rather than the line the parser kept" {
  STACK_ENV=$'# the production state account\n\n*/prod/*  1BAD=SUPERSECRETKEY' \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 3"* ]]
  [[ "$output" != *"SUPERSECRETKEY"* ]]
}

@test "the credential never reaches the log or the pull-request comment" {
  STACK_ENV=$'*  ARM_ACCESS_KEY=SUPERSECRETKEY' run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SUPERSECRETKEY"* ]]
  refute grep -rq 'SUPERSECRETKEY' "${WORK}/tg" 2>/dev/null
}


# --- push to the default branch --------------------------------------------------------------
#
# The failure this section fixes: the target planned on every merge and applied on none,
# because a push event carries no pull request and the approval that authorises the apply
# belongs to the pull request the commit was merged from.
#
# It is behind `terragrunt-apply-on-merge`, off by default, so every case that expects an
# apply-on-merge sets APPLY_ON_MERGE=true. The two tests immediately below are what keep that
# default honest, and they are the regression guard for the silent behaviour change: a caller
# pinned to the published tag, with `on: push: branches: [main]` and terragrunt-apply left at
# `auto`, must keep planning and applying nothing when they take a new patch release.

# A recorder in place of resolve-merged-pr.sh, so "was never invoked" is a fact rather than an
# inference from a missing curl line.
merge_recorder() {
  cat >"${WORK}/resolve-recorder.sh" <<'RECEOF'
#!/usr/bin/env bash
: >"${WORK}/resolve-was-run"
printf '123\n'
RECEOF
  chmod +x "${WORK}/resolve-recorder.sh"
  export RESOLVE_MERGED_PR_BIN="${WORK}/resolve-recorder.sh"
}

@test "REGRESSION, the terragrunt-apply-on-merge default: a push whose commit came from an APPROVED merged pull request plans only, so taking a new release never silently starts applying every changed stack on merge" {
  approved
  merged
  EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  # Neither call is made: no commit-to-pull-request lookup, no approval read. The default push
  # path is exactly what it was before the merged path existed.
  refute grep -q '/commits/' "$STUB_LOG"
  refute grep -q '/reviews' "$STUB_LOG"
  [[ "$output" == *"terragrunt-apply-on-merge is off"* ]]
}

@test "REGRESSION, the terragrunt-apply-on-merge default: resolve-merged-pr.sh is never invoked on a default push, so the default cannot be failed by an outage in a lookup it does not need" {
  merge_recorder
  approved
  merged
  EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ ! -f "${WORK}/resolve-was-run" ]
  [ "$(output_value applied)" = "false" ]
}

@test "a push whose commit was merged from an approved pull request applies, instead of planning on every merge and applying on none" {
  approved
  merged
  APPLY_ON_MERGE=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
  [ "$(output_value approvers)" = "@reviewer" ]
  grep -q 'terragrunt apply' "$STUB_LOG"
  # The reviews it read are #123's, not some other pull request's.
  grep -q '/pulls/123/reviews' "$STUB_LOG"
}

@test "a push from no merged pull request plans, reports and applies nothing, so a direct push cannot apply unreviewed" {
  APPLY_ON_MERGE=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  [[ "$output" == *"no merged pull request"* ]]
  # neutral, not action_required: nothing blocks a commit that is already on the branch, and
  # turning the default branch red is not what fixes an unapproved merge.
  grep -q '"conclusion": "neutral"' "$STUB_LOG"
  # No pull request in scope, so no comment is attempted at all.
  refute grep -q '/comments' "$STUB_LOG"
}

@test "a merged pull request with no independent approval is reported on its own thread as neutral, never as the action_required check that would turn the default branch red over a merge nothing can block" {
  merged
  APPLY_ON_MERGE=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  grep -q '#123 was merged without an independent approval' "${WORK_DIR}/comment.md"
  grep -q 'were not applied' "${WORK_DIR}/comment.md"
  grep -q '/issues/123/comments' "$STUB_LOG"
  # The conclusion and the title, not just the comment. The predicate for action_required is
  # PR_NUMBER (an open pull request in the event) and not gate_pr: a check published against a
  # commit already on the branch has no merge left to block, and swapping the two here is a
  # one-word edit that nothing else in the suite would notice.
  grep -q '"conclusion": "neutral"' "$STUB_LOG"
  grep -q 'Planned; not applied' "$STUB_LOG"
  refute grep -q '"conclusion": "action_required"' "$STUB_LOG"
  refute grep -q 'Apply required before merge' "$STUB_LOG"
}

@test "reviews that cannot be read on the merged path fail the run loudly, so an API outage never goes quietly green as 'nobody approved'" {
  merged
  APPLY_ON_MERGE=true REVIEWS_EXIT=22 EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  # Published before the run died, or the failure is invisible where anyone would look.
  grep -q '"conclusion": "failure"' "$STUB_LOG"
  grep -q 'Could not check the approval' "$STUB_LOG"
  grep -q 'could not be read' "${WORK_DIR}/comment.md"
}

@test "an unreadable review list on a merged push where every stack plans clean exits 0 with a success check, because refusing to apply nothing is not a refusal and the same run's comment already says there was nothing to apply" {
  merged
  APPLY_ON_MERGE=true REVIEWS_EXIT=22 PLAN_EXIT=0 EVENT_NAME=push \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  [ "$(output_value plan-changes)" = "0" ]
  grep -q '"conclusion": "success"' "$STUB_LOG"
  grep -q 'No changes to apply' "$STUB_LOG"
  # The check run and the comment agree, which is the point: before this they did not.
  grep -q 'Nothing to apply' "${WORK_DIR}/comment.md"
  refute grep -q '"conclusion": "failure"' "$STUB_LOG"
}

@test "a commit-to-pull-request lookup that cannot be read fails an auto run rather than applying or skipping on a guess" {
  APPLY_ON_MERGE=true MERGED_PULLS_EXIT=22 EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  [[ "$output" == *"cannot tell whether the change was approved"* ]]
}

@test "an unreadable commit-to-pull-request lookup publishes the check run and the step outputs BEFORE it fails the run, so a required check is never left never reporting on that commit" {
  APPLY_ON_MERGE=true MERGED_PULLS_EXIT=22 EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  grep -q 'check-runs' "$STUB_LOG"
  grep -q '"conclusion": "failure"' "$STUB_LOG"
  # The title names the lookup, not the reviews: they are different outages with different fixes.
  grep -q 'Could not resolve the merged pull request' "$STUB_LOG"
  [ "$(output_value stacks)" = "1" ]
  [ "$(output_value plan-changes)" = "1" ]
  [ "$(output_value applied)" = "false" ]
  # The check run and the outputs, and NOT a comment: the lookup is the thing that would have
  # said which thread to comment on. The check run is the whole of what is published here, and
  # the code comment beside the flag says exactly that rather than claiming a comment.
  refute grep -q '/issues/' "$STUB_LOG"
  # The body is still rendered; what is missing is the gate section, because gate_pr is empty.
  refute grep -q '### Apply' "${WORK_DIR}/comment.md"
}

@test "an unreadable lookup says the lookup was unreadable, and never that the commit came from no merged pull request, because those are the two answers the whole path exists to keep apart" {
  APPLY_ON_MERGE=true MERGED_PULLS_EXIT=22 EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"came from no merged pull request"* ]]
  refute grep -q 'came from no merged pull request' "$GITHUB_STEP_SUMMARY"
  # The step summary carries the same reason the check run does.
  grep -q 'could not be read' "$GITHUB_STEP_SUMMARY"
}

@test "an unreadable lookup on a merged push where every stack plans clean exits 0 with a success check, the same guard the unreadable review list already has: refusing to apply nothing is not a refusal" {
  APPLY_ON_MERGE=true MERGED_PULLS_EXIT=22 PLAN_EXIT=0 EVENT_NAME=push \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  [ "$(output_value plan-changes)" = "0" ]
  grep -q '"conclusion": "success"' "$STUB_LOG"
  grep -q 'No changes to apply' "$STUB_LOG"
  refute grep -q '"conclusion": "failure"' "$STUB_LOG"
  # Still said out loud, because a token missing `pull-requests: read` is a standing
  # misconfiguration and must not stay invisible until the first merge that changes something.
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"could not read the pull requests"* ]]
}

@test "the same lookup failure under apply=never only costs the comment, because that mode never consults an approval" {
  APPLY_ON_MERGE=true MERGED_PULLS_EXIT=22 APPLY=never EVENT_NAME=push \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  [[ "$output" == *"the plan comment has nowhere to go"* ]]
}

@test "an applying run rewrites the same comment rather than leaving it on 'applying now' for ever" {
  approved
  merged
  EXISTING_COMMENTS='[{"id":99,"body":"<!-- tremvok:terragrunt -->earlier plan"}]' \
    APPLY_ON_MERGE=true EVENT_NAME=push run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  # Two writes, both PATCHes of comment 99: one comment, edited, not a second one posted.
  # `--data` carries newlines, so the verb and the URL land on different lines of the log.
  [ "$(grep -c -- '--request PATCH' "$STUB_LOG")" -eq 2 ]
  [ "$(grep -c 'issues/comments/99' "$STUB_LOG")" -eq 2 ]
  refute grep -qE '^https://[^ ]*/issues/123/comments$' "$STUB_LOG"
  grep -q 'Applied' "${WORK_DIR}/comment.md"
  refute grep -q 'applying now' "${WORK_DIR}/comment.md"
}

@test "a pull_request run is unchanged by the push path: the same gate wording and the same action_required conclusion" {
  PR_NUMBER=42 EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'Waiting for an independent approval' "${WORK_DIR}/comment.md"
  grep -q '"conclusion": "action_required"' "$STUB_LOG"
  grep -q 'Apply required before merge' "$STUB_LOG"
  # No commit-to-pull-request lookup: the event already carries the number.
  refute grep -q '/commits/' "$STUB_LOG"
}

@test "apply-on-merge on a pull request looks up nothing, because the event already carries the number and the lookup is only for a push" {
  approved
  APPLY_ON_MERGE=true PR_NUMBER=42 EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  refute grep -q '/commits/' "$STUB_LOG"
  # And it applies nothing: a `pull_request` run is not an apply authorisation, whatever
  # approval the pull request is already carrying. See the section below.
  [ "$(output_value applied)" = "false" ]
}

@test "scope auto on a manual run plans the estate, and the whole estate only while no pull request is in scope" {
  SCOPE=auto EVENT_NAME=workflow_dispatch run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope=all"* ]]

  SCOPE=auto EVENT_NAME=workflow_dispatch PR_NUMBER=1234     run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope=changed"* ]]
}

@test "a scheduled drift run reports what has moved, and with terragrunt-apply-on-merge off it publishes the conclusion it publishes today rather than a new one" {
  SCOPE=all EVENT_NAME=schedule run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  [[ "$output" == *"no pull request is in scope"* ]]
  # Not "this commit came from no merged pull request": a schedule never looked one up.
  [[ "$output" != *"came from no merged pull request"* ]]
  # `action_required`, the same conclusion this run has always published. `neutral` is the
  # better answer for a commit no merge is waiting on, but it is still a DIFFERENT answer, and
  # somebody may be watching for this one on the drift cron. It is gated on the input, so a
  # caller who opts into nothing keeps what they have.
  grep -q '"conclusion": "action_required"' "$STUB_LOG"
  refute grep -q '"conclusion": "neutral"' "$STUB_LOG"
}

@test "the same scheduled drift run publishes neutral once terragrunt-apply-on-merge is on, because that caller has opted into the merged-apply path and its conclusions" {
  SCOPE=all APPLY_ON_MERGE=true EVENT_NAME=schedule run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  grep -q '"conclusion": "neutral"' "$STUB_LOG"
  grep -q 'Planned; not applied' "$STUB_LOG"
  # And no lookup: the gate on the merged path is the event, not the input.
  refute grep -q '/commits/' "$STUB_LOG"
}


# --- a standing approval is not an apply authorisation ---------------------------------------
#
# The failure this section fixes: `auto` set may_apply purely on "the pull request has an
# approval", with nothing said about the event. A reviewer approves commit A, the author
# pushes commit B, and the `pull_request` run for B reads the same standing approval and
# applies B. Nobody reviewed B. It is only safe on a repository whose branch protection
# dismisses stale reviews on push, which this action can neither see nor require.

@test "REGRESSION: a plain pull_request run with a standing approval plans and reports rather than applying, so a commit pushed after an approval is never applied unreviewed" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value plan-changes)" = "1" ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  # The approval is still read and still reported: it is the apply that waits, not the review.
  [ "$(output_value approvers)" = "@reviewer" ]
  # Still blocking, so the merge cannot go through with the change unapplied.
  grep -q '"conclusion": "action_required"' "$STUB_LOG"
  grep -q 'Approved, but not applied for this commit' "$STUB_LOG"
}

@test "the gate for a standing approval never claims the run is waiting for an approval, because one is standing and the reviewer would go looking for a review they already left" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  refute grep -q 'Waiting for an independent approval' "${WORK_DIR}/comment.md"
  grep -q 'Approved by @reviewer' "${WORK_DIR}/comment.md"
  grep -q 'no apply has run for this commit' "${WORK_DIR}/comment.md"
  # And how to start one, or the state is a dead end.
  grep -q 'Dismiss the approval and re-approve' "${WORK_DIR}/comment.md"
  grep -q 'terragrunt-apply: force' "${WORK_DIR}/comment.md"
}

@test "REGRESSION: an EDITED approving review does not apply, because a workflow whose pull_request_review trigger has no types: filter also receives edits, and an approval edited today would otherwise apply whatever HEAD is now" {
  # What GitHub sends when somebody fixes a typo in the body of an approval they left weeks
  # ago: action=edited, state=approved, and HEAD is a commit nobody reviewed.
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review EVENT_ACTION=edited REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a DISMISSED review event does not apply, for the same reason an edited one does not" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review EVENT_ACTION=dismissed REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
}

@test "a submitted approval still applies, so the event-action guard does not break the path it protects" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review EVENT_ACTION=submitted REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
}

@test "an approval event spends the approval: the same pull request applies when the run is the approval itself" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=approved \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
  grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "a COMMENTED review does not spend an approval left on an earlier commit, because writing a comment is not approving this one" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review REVIEW_STATE=commented \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
  grep -q 'Approved, but not applied for this commit' "$STUB_LOG"
}

@test "a review event with no state in the payload still applies, because an unset field is evidence of nothing and the approval list is what is left" {
  approved
  PR_NUMBER=42 EVENT_NAME=pull_request_review run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
}

@test "a manual run that names a pull request plans it rather than applying it on the strength of an approval nobody re-gave, because terragrunt-apply: force is the manual authorisation" {
  approved
  SCOPE=changed PR_NUMBER=42 EVENT_NAME=workflow_dispatch run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "false" ]
  refute grep -q 'terragrunt apply' "$STUB_LOG"
}

@test "force is unchanged by the event guard: an operator applies without any approval at all" {
  APPLY=force GITHUB_ACTOR=operator APPLY_OPERATORS=operator PR_NUMBER=42 EVENT_NAME=pull_request \
    run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value applied)" = "true" ]
  grep -q 'terragrunt apply' "$STUB_LOG"
}

# ── the provider-credential preflight, as the deploy path aggregates it ───────────────────
# terragrunt_credentials.bats covers the detection itself. These cover the part only this
# script can get wrong: whether a missing credential stops the run before the first plan, and
# whether the stack's own environment reaches the check the way it reaches the plan.

needs_azure() {
  cat >terraform/aws/prod/api/provider.tf <<'HCL'
provider "azurerm" {
  features {}
}
HCL
  export AZ_BIN="${STUB_BIN}/az"
  stub az 1 ''
}

@test "a stack whose provider has no credential fails BEFORE the first plan" {
  needs_azure
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no credential on this runner"* ]]
  # The whole point: nothing was planned. A plan that runs anyway spends the time this
  # check exists to save and then reports the unreadable provider error instead.
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "the summary groups by cloud and names the stack" {
  needs_azure
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  grep -q '### azure' "$GITHUB_STEP_SUMMARY"
  grep -q 'terraform/aws/prod/api' "$GITHUB_STEP_SUMMARY"
}

@test "warn plans anyway, and says the plan is expected to fail" {
  needs_azure
  TG_CREDENTIAL_PREFLIGHT=warn run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "off checks nothing at all" {
  needs_azure
  TG_CREDENTIAL_PREFLIGHT=off run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is off; not checking"* ]]
  refute grep -q 'az account show' "$STUB_LOG"
}

@test "a credential arriving through terragrunt-stack-env satisfies the check" {
  # The reason the check runs per stack with that stack's environment rather than once with
  # the job's: this credential does not exist until the stack's own run is built.
  cat >terraform/aws/prod/api/provider.tf <<'HCL'
provider "vcd" {
  url = "https://vcd.example.com/api"
}
HCL
  export STACK_ENV='* VCD_API_TOKEN=from-stack-env'
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "an unknown preflight mode is refused rather than read as off" {
  TG_CREDENTIAL_PREFLIGHT=yes run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be auto, warn or off"* ]]
}

# ── the plan comment's size ──────────────────────────────────────────────────────────────

@test "a stack with no changes gets a table row but no plan excerpt" {
  PLAN_EXIT=0 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'aws/prod/api' "${WORK_DIR}/comment.md"
  refute grep -q '<details>' "${WORK_DIR}/comment.md"
}

@test "terminal colour codes do not reach the plan comment" {
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  init) exit 0 ;;
  plan) printf '\033[90m12:00:00.000\033[0m \033[1;32m+\033[0m resource "x" "y" {}\nPlan: 1 to add, 0 to change, 0 to destroy.\n'; exit 2 ;;
esac
exit 0
STUBEOF
  PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'resource "x" "y"' "${WORK_DIR}/comment.md"
  refute grep -q "$(printf '\033')" "${WORK_DIR}/comment.md"
}

# Thirty stacks with 50 KB of plan each: the unbudgeted comment was 180 KB, which GitHub refuses
# and which curl could not even be handed as an argument.
@test "a plan across many large stacks still fits in one comment" {
  for i in $(seq 1 30); do
    mkdir -p "terraform/aws/prod/s${i}"
    touch "terraform/aws/prod/s${i}/terragrunt.hcl"
  done
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  init) exit 0 ;;
  plan) yes '  + resource "azurerm_thing" "padding" { name = "padding padding" }' | head -c 50000
        printf '\nPlan: 1 to add, 0 to change, 0 to destroy.\n'; exit 2 ;;
esac
exit 0
STUBEOF
  SCOPE=all PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -c <"${WORK_DIR}/comment.md")" -lt 65000 ]
  [ "$(grep -c '<details>' "${WORK_DIR}/comment.md")" -eq 31 ]
  grep -q 'Plan: 1 to add' "${WORK_DIR}/comment.md"
}

@test "excerpts too small to be useful are left out for a pointer to the run" {
  COMMENT_BUDGET=3000 PR_NUMBER=42 run bash "${SCRIPTS}/deploy-terragrunt.sh"
  [ "$status" -eq 0 ]
  grep -q 'aws/prod/api' "${WORK_DIR}/comment.md"
  grep -q 'Plan excerpts left out' "${WORK_DIR}/comment.md"
  refute grep -q '<details>' "${WORK_DIR}/comment.md"
}
