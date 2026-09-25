#!/usr/bin/env bats
#
# The status file and the exit code say different things on purpose. A caller that reads only
# the exit code cannot tell "nothing to do" from "something to do", and that difference is what
# decides whether a pull request needs an apply before it merges.

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p stack out
  stub_script terragrunt <<'STUBEOF'
#!/usr/bin/env bash
printf 'terragrunt %s\n' "$*" >>"${STUB_LOG}"
case "$1" in
  init) printf 'Initializing...\n'; exit "${INIT_EXIT:-0}" ;;
  plan) printf 'Plan: 1 to add, 0 to change, 0 to destroy.\n'; exit "${PLAN_EXIT:-2}" ;;
  apply)
    # APPLY_STALE makes the FIRST apply reject the saved plan the way tofu rejects one whose
    # state moved underneath it, and the second (post-re-plan) apply succeed.
    if [ -n "${APPLY_STALE:-}" ] && [ ! -f "${STUB_LOG}.stale-seen" ]; then
      : >"${STUB_LOG}.stale-seen"
      printf 'Error: Saved plan is stale\n'
      exit 1
    fi
    printf 'Apply complete.\n'; exit "${APPLY_EXIT:-0}" ;;
esac
exit 0
STUBEOF
}

@test "detailed-exitcode 0 means no changes, and that is a success" {
  PLAN_EXIT=0 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "no-changes" ]
}

@test "detailed-exitcode 2 means changes, which is also a success" {
  PLAN_EXIT=2 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "changes" ]
}

@test "any other exit code is a failure" {
  PLAN_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
}

@test "a failed init never reaches plan" {
  INIT_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "the plan uses -detailed-exitcode, or none of the above can be told apart" {
  run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q -- '-detailed-exitcode' "$STUB_LOG"
}

@test "output is buffered to a file, not streamed" {
  # Without this a failed apply leaves an empty log group and the reason nowhere at all, and
  # the output could never be redacted before reaching a pull-request comment.
  run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q 'Plan: 1 to add' out/plan.txt
}

@test "apply with no saved plan plans first, and says so" {
  run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  grep -q 'terragrunt init' "$STUB_LOG"
  grep -q 'terragrunt plan' "$STUB_LOG"
  [[ "$output" == *"no saved plan"* ]]
}

@test "the plan is written to a file, so an apply can be the plan that was reviewed" {
  run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q -- '-out=' "$STUB_LOG"
}

@test "a clean plan leaves no plan file behind" {
  # Nothing to apply is not something to apply later. A kept file would make the next apply
  # re-run an empty plan and report it as a change.
  PLAN_EXIT=0 run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  [ ! -f out/plan.tfplan ]
}

@test "apply uses the saved plan rather than planning again" {
  printf 'saved-plan\n' >out/plan.tfplan
  run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [[ "$output" == *"PLAN SOURCE: the saved plan"* ]]
  grep -q 'terragrunt apply .*plan.tfplan' "$STUB_LOG"
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "a saved plan from the plan run is found through PLAN_DIR" {
  # This is what makes the collapse to one job worth anything: plan and apply keep separate
  # output directories so both logs survive, and the plan file crosses between them.
  mkdir -p plandir applydir
  printf 'saved-plan\n' >plandir/plan.tfplan
  PLAN_DIR="${PWD}/plandir" run bash "${SCRIPTS}/terragrunt-run.sh" apply stack applydir
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN SOURCE: the saved plan"* ]]
}

@test "a stale saved plan is re-planned rather than refused, and says which ran" {
  printf 'saved-plan\n' >out/plan.tfplan
  APPLY_STALE=1 run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -eq 0 ]
  [ "$(cat out/status)" = "applied" ]
  [[ "$output" == *"gone stale"* ]]
  grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "an apply that fails for any other reason is not silently re-planned" {
  printf 'saved-plan\n' >out/plan.tfplan
  APPLY_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
  refute grep -q 'terragrunt plan' "$STUB_LOG"
}

@test "a pull request plans without a provider refresh; a scheduled run refreshes" {
  EVENT_NAME=pull_request run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  grep -q -- '-refresh=false' "$STUB_LOG"
  : >"$STUB_LOG"
  EVENT_NAME=schedule run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  refute grep -q -- '-refresh=false' "$STUB_LOG"
}

@test "refresh can be forced on for a pull request" {
  TG_REFRESH=true EVENT_NAME=pull_request run bash "${SCRIPTS}/terragrunt-run.sh" plan stack out
  refute grep -q -- '-refresh=false' "$STUB_LOG"
}

@test "a failed apply is recorded as failed" {
  APPLY_EXIT=1 run bash "${SCRIPTS}/terragrunt-run.sh" apply stack out
  [ "$status" -ne 0 ]
  [ "$(cat out/status)" = "failed" ]
}

@test "redact takes a file and needs no stack" {
  printf 'client_secret = "hunter2"\nfine = "value"\n' >secrets.txt
  run bash "${SCRIPTS}/terragrunt-run.sh" redact secrets.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *'client_secret = "***"'* ]]
  [[ "$output" == *'fine = "value"'* ]]
}

@test "redaction covers access keys and URL credentials too" {
  printf 'AKIAIOSFODNN7EXAMPLE\nhttps://user:pw@host/x\n' >secrets.txt
  run bash "${SCRIPTS}/terragrunt-run.sh" redact secrets.txt
  [[ "$output" != *"IOSFODNN7EXAMPLE"* ]]
  [[ "$output" != *"user:pw@"* ]]
}

@test "an unknown action fails rather than doing something surprising" {
  run bash "${SCRIPTS}/terragrunt-run.sh" destroy stack out
  [ "$status" -ne 0 ]
}
