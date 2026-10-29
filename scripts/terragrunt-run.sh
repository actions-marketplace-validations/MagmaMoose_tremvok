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
#
# **A rolling stack applies one unit at a time.** TG_ROLLING names the `for_each`/`count` blocks
# whose instances are units (`module.node` makes `module.node["worker-0"]` one). When the plan
# changes two or more units, the apply takes them in turn, each with `-target`, waits
# TG_ROLLING_PAUSE seconds between them, and ends with a full plan for whatever is left. One
# apply of the whole plan restarts every VM a cluster resize touches at the same moment, which
# takes the cluster down with it; this is what keeps the rest of it up.
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
# Space-separated addresses whose instances are applied one at a time; empty applies the stack in
# one go, as it always has. deploy-terragrunt.sh resolves them per stack from terragrunt-rolling.
TG_ROLLING="${TG_ROLLING:-}"
TG_ROLLING_PAUSE="${TG_ROLLING_PAUSE:-300}"
# `read -a` rather than an unquoted expansion, which would glob an address holding a `[`.
rolling_addresses=()
read -r -a rolling_addresses <<<"$TG_ROLLING"

# Redact before anything is shown. Terraform marks its own sensitive outputs, but a provider
# can print a token in an error message and a pull-request comment is world-readable on a
# public repository. Matches `name = "value"` where the name looks like a credential, and the
# two other shapes a plan diff prints one in: a quoted map key, `"api_token" = "value"`, and an
# update, whose new value after `->` is as secret as the old one, `null` or not.
redact() {
  local name value
  name='(password|secret|token|api_key|access_key|private_key|client_secret)[a-z_]*"?[[:space:]]*=[[:space:]]*'
  # Escaped quotes and all, so `"pa\"ss"` is masked whole rather than leaving `ss"` behind.
  value='"([^"\\]|\\.)*"'
  sed -E \
    -e "s/(${name})${value}/\\1\"***\"/gI" \
    -e "s/(${name}(${value}|[^\"[:space:]]+)[[:space:]]*->[[:space:]]*)${value}/\\1\"***\"/gI" \
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

# ── rolling apply ────────────────────────────────────────────────────────────────────────
# The resource addresses a plan file changes, one per line, read back with `show` so they come
# from the file that is applied rather than from a log. Only the action lines count: a data source
# `will be read during apply` changes nothing, and the `has changed` lines of a refresh note
# describe drift, not the plan. The match is unanchored because terragrunt can put a timestamp
# and `STDOUT tofu:` in front of every line.
planned_addresses() { # plan-file log-file
  run "$2" show -no-color "$1" || return 1
  LC_ALL=C sed -nE \
    -e "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g" \
    -e 's/^.*# (.+) (will be (created|destroyed|updated in-place|replaced|imported|forgotten|removed)|must be replaced).*$/\1/p' \
    "$2" | sed -E -e 's/ is tainted, so$//' -e 's/ \(deposed object [^)]*\)$//'
}

# The unit an address belongs to: the instance key after the TG_ROLLING address it starts with,
# `["worker-0"]` for `module.node["worker-0"].vcd_vm.this`. Instances of two TG_ROLLING addresses
# that share a key are one unit, the way two `for_each` blocks over one map describe one thing.
# Prints nothing for an address outside every unit.
unit_of() { # address
  local address="$1" prefix rest
  for prefix in ${rolling_addresses[@]+"${rolling_addresses[@]}"}; do
    case "$address" in
      "${prefix}["*) ;;
      *) continue ;;
    esac
    rest="${address#"$prefix"}"
    case "$rest" in
      '["'*) rest="${rest#\[\"}"; printf '["%s"]\n' "${rest%%\"\]*}" ;;
      *) printf '%s]\n' "${rest%%\]*}" ;;
    esac
    return 0
  done
}

# `<unit> <address>` for every address a plan file changes inside a unit, in plan order.
unit_changes() { # plan-file log-file
  local addresses address unit
  addresses="$(planned_addresses "$1" "$2")" || return 1
  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    unit="$(unit_of "$address")"
    if [[ -n "$unit" ]]; then
      printf '%s %s\n' "$unit" "$address"
    fi
  done <<<"$addresses"
}

# The distinct units in unit_changes output, in the order they first appear, and how many.
units_in() { # unit-changes
  printf '%s\n' "$1" | awk 'NF && !seen[$1]++ { print $1 }'
}
unit_count() { # unit-changes
  printf '%s\n' "$1" | awk 'NF && !seen[$1]++ { n++ } END { print n + 0 }'
}

# One plan-and-apply per unit, then one full plan for whatever no unit holds. Exits.
#
# Each unit is planned with a `-target` for its key under EVERY TG_ROLLING address, whether or
# not it has an instance there. tofu plans every instance of a resource a target depends on,
# unless that resource is itself targeted, and then only the targeted instances: so a node with
# no data disk, targeted as `module.node["cp"]` alone, would pull in every other node's disk
# resize, while `-target=disk.data["cp"]` beside it, naming nothing, keeps them out.
#
# The plan is still checked before any of it is applied, and refused when it changes an instance
# of another unit, or an instance outside every unit that is keyed like another unit: a per-unit
# resource nobody listed in TG_ROLLING. Either is the outage this exists to prevent, and failing
# the run is the safe answer to it.
rolling_apply() { # unit-changes
  local changes="$1" unit unit_list=() total i=0 applied=0 prefix step_plan step_log
  local targets step_changes step_addresses address owner other foreign code
  while IFS= read -r unit; do
    if [[ -n "$unit" ]]; then unit_list+=( "$unit" ); fi
  done < <(units_in "$changes")
  total=${#unit_list[@]}
  : >"${out_dir}/apply.txt"
  tremvok::log "ROLLING: ${total} units of ${stack} change; applying them one at a time, ${TG_ROLLING_PAUSE}s apart (${TG_ROLLING})"

  for unit in "${unit_list[@]}"; do
    i=$(( i + 1 ))
    # Before the plan rather than after the last apply, so the plan reads the state as it is
    # when it is applied, not as it was a pause ago.
    if (( applied > 0 )); then
      tremvok::log "ROLLING: waiting ${TG_ROLLING_PAUSE}s for the last unit to come back before ${unit}"
      sleep "$TG_ROLLING_PAUSE"
    fi

    targets=()
    for prefix in "${rolling_addresses[@]}"; do
      targets+=( "-target=${prefix}${unit}" )
    done

    step_plan="${PLAN_DIR}/rolling-${i}.tfplan"
    step_log="${out_dir}/rolling-${i}-plan.txt"
    code=0
    # shellcheck disable=SC2086  # deliberate word splitting: timeout_prefix is a command prefix
    ( cd "$stack" && $timeout_prefix "$TG_BIN" plan -input=false -lock-timeout=5m \
        -detailed-exitcode -out="$step_plan" ${targets[@]+"${targets[@]}"} \
        ${refresh[@]+"${refresh[@]}"} ${extra[@]+"${extra[@]}"} ) >"$step_log" 2>&1 || code=$?
    cat "$step_log" >>"${out_dir}/apply.txt"
    case $code in
      0)
        # An earlier run that stopped part-way applied it already.
        rm -f "$step_plan"
        tremvok::log "ROLLING ${i}/${total}: ${unit} has nothing left to change"
        continue ;;
      2) ;;
      *)
        printf 'failed\n' >"${out_dir}/status"
        tremvok::error "ROLLING ${i}/${total}: the plan for ${unit} failed. ${applied} unit(s) before it were applied."
        exit "$code" ;;
    esac

    step_addresses="$(planned_addresses "$step_plan" "${out_dir}/rolling-${i}-show.txt")" || {
      printf 'failed\n' >"${out_dir}/status"
      tremvok::error "ROLLING ${i}/${total}: could not read back the plan for ${unit}, so it was not applied."
      exit 1
    }
    foreign=""
    while IFS= read -r address; do
      if [[ -z "$address" ]]; then continue; fi
      owner="$(unit_of "$address")"
      if [[ -z "$owner" ]]; then
        for other in "${unit_list[@]}"; do
          case "$address" in
            *"$other"*) if [[ "$other" != "$unit" ]]; then owner="$other"; fi ;;
          esac
        done
      fi
      if [[ -n "$owner" && "$owner" != "$unit" ]]; then foreign="${foreign} ${address}"; fi
    done <<<"$step_addresses"
    if [[ -n "$foreign" ]]; then
      printf 'failed\n' >"${out_dir}/status"
      tremvok::error "ROLLING ${i}/${total}: ${unit} cannot be applied on its own, because its targeted plan also changes${foreign}, which belong to other units. Nothing of ${unit} was applied; ${applied} unit(s) before it were. If one of them is a per-unit resource, add its block to terragrunt-rolling so each unit takes its own; otherwise apply this change one unit at a time by hand."
      exit 1
    fi

    if ! run "${out_dir}/rolling-${i}-apply.txt" apply -input=false -no-color -lock-timeout=5m "$step_plan"; then
      cat "${out_dir}/rolling-${i}-apply.txt" >>"${out_dir}/apply.txt"
      printf 'failed\n' >"${out_dir}/status"
      tremvok::error "ROLLING ${i}/${total}: the apply of ${unit} failed. ${applied} unit(s) before it were applied."
      exit 1
    fi
    cat "${out_dir}/rolling-${i}-apply.txt" >>"${out_dir}/apply.txt"
    rm -f "$step_plan"
    applied=$(( applied + 1 ))
    tremvok::log "ROLLING ${i}/${total}: ${unit} applied"
  done

  # What no unit holds, and the proof that every unit landed. Changes to two or more units here
  # appeared while the roll ran, and applying them together is the thing this refuses to do.
  tremvok::log "ROLLING: ${applied} of ${total} units applied; planning ${stack} in full for anything outside them"
  code=0
  do_plan || code=$?
  cat "${out_dir}/plan.txt" >>"${out_dir}/apply.txt"
  case $code in
    0) printf 'applied\n' >"${out_dir}/status"; exit 0 ;;
    2) ;;
    *) printf 'failed\n' >"${out_dir}/status"; exit "$code" ;;
  esac
  step_changes="$(unit_changes "$plan_file" "${out_dir}/show.txt")" || {
    printf 'failed\n' >"${out_dir}/status"
    tremvok::error "ROLLING: could not read back the final plan for ${stack}, so it was not applied."
    exit 1
  }
  if (( $(unit_count "$step_changes") > 1 )); then
    printf 'failed\n' >"${out_dir}/status"
    tremvok::error "ROLLING: after the roll, the plan for ${stack} still changes several units at once; they changed while it ran. Nothing more was applied. Re-run the apply to roll them."
    exit 1
  fi
  if run "${out_dir}/final-apply.txt" apply -input=false -no-color -lock-timeout=5m "$plan_file"; then
    cat "${out_dir}/final-apply.txt" >>"${out_dir}/apply.txt"
    rm -f "$plan_file"
    printf 'applied\n' >"${out_dir}/status"
    exit 0
  fi
  cat "${out_dir}/final-apply.txt" >>"${out_dir}/apply.txt"
  printf 'failed\n' >"${out_dir}/status"
  exit 1
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
    # A rolling stack whose plan changes two or more units is applied unit by unit, never from
    # the saved plan in one go. One unit or none is not a roll, and applies below as it always
    # has. The units come from the plan about to be applied: the saved one, or one made here.
    planned_here=false
    if [[ -n "$TG_ROLLING" ]]; then
      if [[ ! -s "$plan_file" ]]; then
        tremvok::log "PLAN SOURCE: no saved plan for ${stack}; planning now"
        planned_here=true
        code=0
        do_plan || code=$?
        case $code in
          0) exit 0 ;;
          2) ;;
          *) printf 'failed\n' >"${out_dir}/status"; exit "$code" ;;
        esac
      fi
      changes="$(unit_changes "$plan_file" "${out_dir}/show.txt")" || {
        printf 'failed\n' >"${out_dir}/status"
        tremvok::error "could not read back the plan for ${stack}, so the units it changes are unknown and nothing was applied."
        exit 1
      }
      if (( $(unit_count "$changes") > 1 )); then
        rolling_apply "$changes"
      fi
    fi

    if [[ -s "$plan_file" ]]; then
      if [[ "$planned_here" == true ]]; then
        tremvok::log "PLAN SOURCE: the plan just made (${plan_file})"
      else
        tremvok::log "PLAN SOURCE: the saved plan (${plan_file})"
      fi
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
