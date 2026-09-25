#!/usr/bin/env bash
# Plan or apply one Terragrunt stack, buffered, redacted, and with a status file.
#
# Output is buffered to a file rather than streamed because a plan is long, several stacks run
# in sequence, and the interesting part is the last forty lines. Buffering it also means it can
# be redacted before it reaches a pull-request comment.
#
# The exit code and the status file say different things on purpose:
#   status=no-changes  planned clean
#   status=changes     planned with a diff
#   status=failed      the tool errored
# A caller that only reads the exit code cannot tell "nothing to do" from "something to do",
# and that difference is what decides whether a pull request needs an apply before it merges.
#
# **A plan is saved and re-used.** `plan` writes `-out=plan.tfplan`; `apply` applies that file
# when it is still valid, so what lands is the diff a human reviewed rather than whatever the
# configuration produces a second time. When the saved plan has gone stale — state moved
# underneath it — the apply says so in the log and re-plans, because refusing to apply an
# approved change because the world moved on is worse than applying the newer plan loudly.
# That trade is the reason the log line exists: `PLAN SOURCE:` names which one ran.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action="${1:-plan}"

TG_BIN="${TG_BIN:-terragrunt}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
TG_REFRESH="${TG_REFRESH:-auto}"
TG_TIMEOUT="${TG_TIMEOUT:-900}"
TG_LOG_LEVEL="${TG_LOG_LEVEL:-}"
EVENT_NAME="${EVENT_NAME:-}"
# Whether a PLAN holds the state lock. deploy-terragrunt.sh sets it false for the runs a newer
# push or review cancels, because a plan writes nothing to state and a cancelled tofu can be
# killed before it releases the lock, which then fails every later run on that stack until
# somebody force-unlocks it by hand. It is read by the `plan` action only: an apply, and the
# re-plan inside one, always lock, because that is what stops two applies writing at once.
TG_STATE_LOCK="${TG_STATE_LOCK:-true}"

# Redact before anything is shown. Terraform marks its own sensitive outputs, but a provider
# can print a token in an error message and a pull-request comment is world-readable on a
# public repository. Matches `name = "value"` where the name looks like a credential.
redact() {
  sed -E \
    -e 's/((password|secret|token|api_key|access_key|private_key|client_secret)[a-z_]*[[:space:]]*=[[:space:]]*)"[^"]*"/\1"***"/gI' \
    -e 's/(AKIA|ASIA)[A-Z0-9]{16}/\1****************/g' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g'
}

# Handled before the plan/apply argument checks: `redact` takes a file, not a stack.
if [[ "$action" == "redact" ]]; then
  redact <"${2:-/dev/stdin}"
  exit 0
fi

stack="${2:-}"
out_dir="${3:-}"
[[ -n "$stack" ]] || tremvok::fail "usage: terragrunt-run.sh plan|apply <stack> <output-dir>"
[[ -n "$out_dir" ]] || tremvok::fail "usage: terragrunt-run.sh plan|apply <stack> <output-dir>"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# Where a saved plan for this stack lives. Defaults to the output directory, which is what
# `plan` uses; `apply` is pointed at the plan run's directory instead.
PLAN_DIR="${PLAN_DIR:-$out_dir}"
[[ -d "$PLAN_DIR" ]] && PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
plan_file="${PLAN_DIR}/plan.tfplan"

# A stalled provider call otherwise looks like a silent hang until the job's own limit, which
# is measured in hours. `timeout` is GNU coreutils and is not on every runner, so its absence
# degrades to no timeout rather than to a broken command.
timeout_prefix=""
if [[ "$TG_TIMEOUT" != "0" ]] && command -v timeout >/dev/null 2>&1; then
  timeout_prefix="timeout $TG_TIMEOUT"
fi

# Config-versus-state is enough for a pull-request check, and a full provider refresh of a
# large estate is the slowest part of the run. The scheduled drift run is the one that has to
# ask the provider, so `auto` keeps the refresh everywhere except a pull request.
refresh_flag=""
case "$TG_REFRESH" in
  false) refresh_flag="-refresh=false" ;;
  true) refresh_flag="" ;;
  auto|*) [[ "$EVENT_NAME" == "pull_request" ]] && refresh_flag="-refresh=false" ;;
esac

if [[ -n "$TG_LOG_LEVEL" ]]; then
  export TF_LOG="$TG_LOG_LEVEL" TF_LOG_PATH="${out_dir}/tf-debug.log"
fi

# No `set +e`/`set -e` toggling anywhere in here. A function that re-enables errexit hands it
# back ON to a caller that had deliberately turned it off, so the caller's next non-zero
# command kills the run — which is exactly how the saved-plan branch below would have exited
# before ever reporting a status. Instead every fallible command is captured with `|| code=$?`,
# which errexit exempts, and callers test the code.
run() { # log-file  args...
  local log="$1"; shift
  local code=0
  # shellcheck disable=SC2086  # deliberate word splitting: timeout_prefix is a command prefix
  ( cd "$stack" && $timeout_prefix "$TG_BIN" "$@" ) >"$log" 2>&1 || code=$?
  return $code
}

# Wait up to five minutes for a lock another run holds. Replaced by -lock=false in the `plan`
# action below when the caller asked for a lock-free plan; never touched for an apply.
lock_flags=( -lock-timeout=5m )

# shellcheck disable=SC2206  # deliberate word splitting: EXTRA_ARGS is a flag string
extra=( $EXTRA_ARGS )
# shellcheck disable=SC2206  # deliberate word splitting: refresh_flag is empty or one flag
refresh=( $refresh_flag )

do_plan() { # -> 0 no changes, 2 changes, other failed
  local code=0
  if ! run "${out_dir}/init.txt" init -input=false -upgrade=false; then
    cat "${out_dir}/init.txt" >"${out_dir}/plan.txt"
    printf 'failed\n' >"${out_dir}/status"
    return 1
  fi
  # shellcheck disable=SC2086
  ( cd "$stack" && $timeout_prefix "$TG_BIN" plan -input=false "${lock_flags[@]}" \
      -detailed-exitcode -out="$plan_file" \
      ${refresh[@]+"${refresh[@]}"} ${extra[@]+"${extra[@]}"} ) >"${out_dir}/plan.txt" 2>&1 \
    || code=$?
  # `-detailed-exitcode`: 0 no changes, 2 changes, anything else an error. Without it the only
  # way to tell "nothing to do" from "a diff" is to parse English out of the output.
  case $code in
    0) rm -f "$plan_file"; printf 'no-changes\n' >"${out_dir}/status" ;;
    2) printf 'changes\n' >"${out_dir}/status" ;;
    *) rm -f "$plan_file"; printf 'failed\n' >"${out_dir}/status" ;;
  esac
  return $code
}

case "$action" in
  plan)
    if ! tremvok::is_true "$TG_STATE_LOCK"; then
      lock_flags=( -lock=false )
      tremvok::log "STATE LOCK: this plan does not take it (TG_STATE_LOCK=${TG_STATE_LOCK}); it writes nothing to state, and a cancelled run cannot strand a lock"
    fi
    code=0
    do_plan || code=$?
    case $code in
      0|2) exit 0 ;;
      *) exit "$code" ;;
    esac
    ;;

  apply)
    if [[ -s "$plan_file" ]]; then
      tremvok::log "PLAN SOURCE: the saved plan (${plan_file})"
      code=0
      run "${out_dir}/apply.txt" apply -input=false -no-color -lock-timeout=5m "$plan_file" || code=$?
      if (( code == 0 )); then
        rm -f "$plan_file"
        printf 'applied\n' >"${out_dir}/status"
        exit 0
      fi
      # A stale saved plan is a different thing from a broken apply, and only the first is
      # worth re-planning for. Anything else is reported as the failure it is.
      if ! grep -qiE 'saved plan is stale|plan (file )?is (no longer|not) valid|state (snapshot|data) was created by|Saved plan does not match' "${out_dir}/apply.txt"; then
        printf 'failed\n' >"${out_dir}/status"
        exit "$code"
      fi
      tremvok::warn "the saved plan for ${stack} has gone stale; re-planning before applying. What lands is the newer plan, not the one reviewed."
      rm -f "$plan_file"
    else
      tremvok::log "PLAN SOURCE: no saved plan for ${stack}; planning now"
    fi

    code=0
    do_plan || code=$?
    if (( code != 0 && code != 2 )); then
      printf 'failed\n' >"${out_dir}/status"
      exit "$code"
    fi
    if (( code == 0 )); then
      printf 'no-changes\n' >"${out_dir}/status"
      exit 0
    fi
    if run "${out_dir}/apply.txt" apply -input=false -no-color -lock-timeout=5m "$plan_file"; then
      rm -f "$plan_file"
      printf 'applied\n' >"${out_dir}/status"
      exit 0
    fi
    printf 'failed\n' >"${out_dir}/status"
    exit 1
    ;;

  *)
    tremvok::fail "unknown action '${action}' (expected plan, apply or redact)"
    ;;
esac
