#!/usr/bin/env bash
# The Terragrunt target: discover -> plan -> gate on an approval -> apply.
#
# This is the Atlantis replacement. It exists for one reason that has nothing to do with
# features: Atlantis runs in the cluster and needs a **stored** AWS credential able to create
# IAM roles and policies — which means whatever it can assume, it can also grant itself. The
# same work in GitHub Actions authenticates by OIDC: a role assumed per run, nothing at rest.
# Deleting that credential is a stronger argument than any convenience.
#
# The flow:
#   pull_request           plan every affected stack, comment the result, publish the check
#                          as `action_required` when there is anything to apply. An approval
#                          already standing on the pull request does NOT apply here: see below
#   review (approved)      apply the pull request's merge result, then turn the check green
#   push to the default    plan; and with `terragrunt-apply-on-merge` on, apply what was merged
#   schedule               plan everything (drift), notify on changes or failures
#
# What is deliberately NOT here: applying an unapproved change. An approval is the
# authorisation, and a merge that never had one is *reported* rather than applied — an
# unapproved merge is a branch-protection problem, and turning the default branch red does not
# fix it while leaving the stacks unapplied and invisible would.
#
# Nor is applying a commit whose approval was given to a different one. An approval authorises
# the commit it was given for, so the run applies on the EVENT that grants it and never on the
# state it happens to observe. Approve commit A, push commit B, and a plain `pull_request` run
# for B that read the standing approval would apply B unreviewed; that is only safe where
# branch protection dismisses stale reviews on push, which this action can neither see nor
# require. B is planned and reported instead, and re-approving is what applies it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${here}/lib/common.sh"

ROOT_DIR="${ROOT_DIR:-terraform}"
SCOPE="${SCOPE:-auto}"                 # auto | all | changed
CHANGED_FILES="${CHANGED_FILES:-}"     # a file listing changed paths
EVENT_NAME="${EVENT_NAME:-}"
# The review's own state on a `pull_request_review` event, from the event payload. Empty on
# every other event, and empty when the caller's action.yml predates this field.
REVIEW_STATE="${REVIEW_STATE:-}"
PR_NUMBER="${PR_NUMBER:-}"
HEAD_SHA="${HEAD_SHA:-}"
APPLY="${APPLY:-auto}"                 # auto | never | force
# Whether a push to the default branch may apply what was merged. Off by default, and that
# default is load-bearing: a caller pinned to the published tag with `on: push` has always
# planned on a merge and applied on none, and a default that quietly starts applying every
# changed stack is not a change anyone reviews in their own diff. Off, the whole merged-pull-
# request path below is skipped: no lookup, no approval read, plan only.
APPLY_ON_MERGE="${APPLY_ON_MERGE:-false}"
# Comma-separated GitHub logins allowed to force an apply by hand. Unset means nobody can:
# the manual path fails closed. The normal path is an independent approval and needs none.
APPLY_OPERATORS="${APPLY_OPERATORS:-}"
# Per-stack environment. One `<glob> KEY=VALUE` per line, first match wins, so a specific
# pattern goes above the catch-all exactly as it would in a `case`. Exists because a state
# backend credential is per-account, not per-run: an estate whose prd state lives in a
# different account (a deliberate blast-radius boundary, not an accident) cannot be planned
# with one credential, and without this the choice is one job per credential class.
STACK_ENV="${STACK_ENV:-}"
# auto | warn | off. See terragrunt-credentials.sh. `auto` fails the run, and that is the
# default because the failure it replaces costs a full plan cycle across every stack to say
# less than this does in one line.
TG_CREDENTIAL_PREFLIGHT="${TG_CREDENTIAL_PREFLIGHT:-auto}"
# auto | always. Whether a plan takes the state lock; see "does a plan take the state lock?" below.
TG_PLAN_LOCK="${TG_PLAN_LOCK:-auto}"
CHECK_NAME="${CHECK_NAME:-Terragrunt apply}"
RUN_URL="${RUN_URL:-}"
WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/tremvok-terragrunt}"
DRY_RUN="${DRY_RUN:-false}"
MAX_COMMENT_EXCERPT="${MAX_COMMENT_EXCERPT:-6000}"
# What the whole plan comment may use. GitHub refuses one over 65,536 characters; this leaves
# room for notify-pr.sh's marker and counts characters, so the total stays inside GitHub's limit.
COMMENT_BUDGET="${COMMENT_BUDGET:-60000}"
# Overridable so the tests can put a recorder in front of it and assert it was never run;
# production always uses the script next to this one. Same shape as VAULT_READ_BIN in
# deploy-ansible.sh.
RESOLVE_MERGED_PR_BIN="${RESOLVE_MERGED_PR_BIN:-${here}/resolve-merged-pr.sh}"

mkdir -p "$WORK_DIR"

# ── nothing from a stack-env line is ever echoed whole ───────────────────────────────────
# terragrunt-stack-env exists to carry per-stack state-backend credentials, so everything from
# the first `=` onwards is a secret by assumption. A guard that refuses a malformed line by
# printing it is worse than no guard: the ::error:: annotation and the step summary are as
# public as the repository. Every message below names the line INDEX, the glob and the KEY,
# and nothing else.

# The glob half. It needs the same cut as the assignment half, because a line with no
# whitespace at all (`ARM_ACCESS_KEY=…`, the glob forgotten) is exactly the mistake somebody
# makes with a credential in hand, and it puts the whole assignment in the glob slot.
# The glob half, and only when it is ACTUALLY a glob.
#
# Cutting the token at its first `=` is not enough, and the case that breaks it is the likely
# one: a YAML block scalar whose long value wrapped onto its own line leaves a bare credential
# alone in the glob slot. A base64 state-backend key has no `=` until the `==` padding at the
# very end, so "everything before the first `=`" is the whole key, printed into an ::error::
# annotation by the guard whose job was to keep it out of one.
#
# A real glob is a path pattern: it holds no `=`, no whitespace, and is short. Anything else is
# not a glob, so there is nothing safe to quote from it and the index is the whole report.
stack_env_glob_label() { # glob
  case "$1" in
    *=*) printf '%s' 'not a glob (it contains "="), so it is named by line number only' ;;
    "") printf '%s' 'empty' ;;
    # Positive test, not a blocklist. A stack glob matches a directory path, so it carries a
    # `/` or a `*`; a bare token with neither is not one, and a short secret is indis-
    # tinguishable from a short word. Only quote what looks like the thing it claims to be.
    */*|*'*'*) if (( ${#1} > 64 )); then
                 printf '%s' 'not a glob (too long to be a path pattern), so it is named by line number only'
               else
                 printf "'%s'" "$1"
               fi ;;
    *) printf '%s' 'not a glob (no "/" or "*" in it), so it is named by line number only' ;;
  esac
}

# The assignment half, named rather than printed.
stack_env_key_label() { # assignment
  case "$1" in
    =*) printf '%s' 'an empty key' ;;
    *=*) printf "key '%s'" "${1%%=*}" ;;
    # No `=` at all means there is no KEY to name and what is there could be anything: a value
    # whose `=` was mistyped, or a password pasted a line early. Described, never printed.
    *) printf '%s' "no '=' in it at all" ;;
  esac
}

# Emits the KEY=VALUE lines that apply to one stack: every line whose glob matches, first
# match per KEY winning. Deliberately NOT eval'd, and deliberately not echoed: these values
# are credentials.
validate_stack_env() {
  local line pattern assignment index=0
  [[ -n "$STACK_ENV" ]] || return 0
  while IFS= read -r line; do
    # Counted before the skips, so the index names the line the caller actually typed.
    index=$(( index + 1 ))
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != '#'* ]] || continue
    pattern="${line%%[[:space:]]*}"
    assignment="${line#"$pattern"}"
    assignment="${assignment#"${assignment%%[![:space:]]*}"}"
    [[ -n "$assignment" ]] \
      || tremvok::fail "terragrunt-stack-env line ${index} has a glob but no KEY=VALUE after it: $(stack_env_glob_label "$pattern"). The line is named by index, glob and key and never printed: this input carries credentials, and an ::error:: annotation is as public as the repository."
    case "$assignment" in
      [A-Za-z_]*=*) ;;
      *) tremvok::fail "terragrunt-stack-env line ${index} does not assign a KEY=VALUE: the glob is $(stack_env_glob_label "$pattern") and what follows it has $(stack_env_key_label "$assignment"). A KEY starts with a letter or an underscore. The line is named by index, glob and key and never printed: this input carries credentials." ;;
    esac
  done <<<"$STACK_ENV"
}

stack_env_for() { # stack
  local stack="$1" line pattern assignment key
  local seen=""
  [[ -n "$STACK_ENV" ]] || return 0
  while IFS= read -r line; do
    # Leading and trailing whitespace, and blank or commented lines, are the difference
    # between a YAML block scalar a human wrote and one a parser likes.
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != '#'* ]] || continue
    pattern="${line%%[[:space:]]*}"
    assignment="${line#"$pattern"}"
    assignment="${assignment#"${assignment%%[![:space:]]*}"}"
    # shellcheck disable=SC2254  # the pattern is data on purpose: it is a glob from input
    case "$stack" in
      $pattern) ;;
      *) continue ;;
    esac
    key="${assignment%%=*}"
    case " ${seen} " in
      *" ${key} "*) continue ;;   # an earlier line already set it; first match wins
    esac
    seen="${seen}${key} "
    printf '%s\n' "$assignment"
  done <<<"$STACK_ENV"
}

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/-$//'; }

# `sed 's/^./\U&/'` is a GNU extension that BSD sed (macOS) silently does not apply, so the
# first character is upper-cased by hand.
capitalize() {
  printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

validate_stack_env

# ── which stacks ─────────────────────────────────────────────────────────────────────────
scope="$SCOPE"
if [[ "$scope" == "auto" ]]; then
  if [[ -n "$PR_NUMBER" ]]; then
    # A pull request is in scope however it got here, from the event or named by hand with
    # terragrunt-pull-request. Either way `auto` means the stacks that pull request touches.
    # A no-op when the override is empty: PR_NUMBER is otherwise non-empty only on
    # pull_request and pull_request_review, where `auto` already meant `changed`.
    scope="changed"
  else
    case "$EVENT_NAME" in
      schedule|workflow_dispatch) scope="all" ;;
      *) scope="changed" ;;
    esac
  fi
fi

# `while read` rather than `mapfile`, which is bash 4 — see the note in lib/common.sh. The
# loop also drops blank lines, which mapfile would have kept as empty array elements.
stacks=()
discover_output=""
if [[ "$scope" == "all" ]]; then
  discover_output="$(ROOT_DIR="$ROOT_DIR" "${here}/terragrunt-discover.sh" all)"
else
  [[ -n "$CHANGED_FILES" && -f "$CHANGED_FILES" ]] \
    || tremvok::fail "scope=changed needs changed-files to point at a file listing the changed paths"
  discover_output="$(ROOT_DIR="$ROOT_DIR" "${here}/terragrunt-discover.sh" changed "$CHANGED_FILES")"
fi
while IFS= read -r stack; do
  [[ -n "$stack" ]] && stacks+=("$stack")
done <<<"$discover_output"

tremvok::log "discovered ${#stacks[@]} stack(s) (scope=${scope})"

if (( ${#stacks[@]} == 0 )); then
  tremvok::summary "## Terragrunt — nothing affected"
  tremvok::summary ""
  tremvok::summary "The changed files map to no automated stack, so there is nothing to plan or apply."
  # The check still reports. A required check that stays silent blocks the pull request
  # forever, and "this change touches no Terraform" is a perfectly good success.
  CHECK_NAME="$CHECK_NAME" HEAD_SHA="$HEAD_SHA" CONCLUSION=success \
    TITLE="No Terraform stacks affected" DETAILS_URL="$RUN_URL" \
    SUMMARY="This change maps to no automated stack, so there is nothing to apply." \
    "${here}/publish-check.sh"
  tremvok::set_output stacks 0
  tremvok::set_output plan-changes 0
  tremvok::set_output applied false
  tremvok::set_output deployed true
  exit 0
fi

# ── does this runner hold the credentials the stacks' providers need ─────────────────────
# Before the first plan, because the failure it catches is the one this action reports worst:
# the state backend's credential is supplied per stack and the PROVIDERS' is not, so init
# succeeds, the plan starts, and every stack in turn dies inside a provider with a message
# naming a generated file and no credential. See terragrunt-credentials.sh for what it reads.
#
# Per stack and with that stack's own environment applied, the same way its plan is invoked:
# a credential that arrives through `terragrunt-stack-env` is invisible to a check run
# without it, and a false alarm is how a guard like this gets switched off.
credential_report="${WORK_DIR}/credentials-missing.tsv"
: >"$credential_report"

case "$TG_CREDENTIAL_PREFLIGHT" in
  auto | warn | off) ;;
  *) tremvok::fail "terragrunt-credential-preflight must be auto, warn or off (got '${TG_CREDENTIAL_PREFLIGHT}')" ;;
esac

if [[ "$TG_CREDENTIAL_PREFLIGHT" == "off" ]]; then
  tremvok::log "terragrunt-credential-preflight is off; not checking provider credentials"
else
  printf '::group::provider credential preflight\n'
  for stack in "${stacks[@]}"; do
    stack_env=()
    while IFS= read -r assignment; do
      [[ -n "$assignment" ]] && stack_env+=( "$assignment" )
    done < <(stack_env_for "$stack")
    # Not `|| true`: the report file is the result, and a non-zero exit here only means this
    # stack contributed a row to it. Under errexit the call has to be in a condition.
    if env ${stack_env[@]+"${stack_env[@]}"} \
         ROOT_DIR="$ROOT_DIR" CREDENTIAL_REPORT="$credential_report" \
         "${here}/terragrunt-credentials.sh" "$stack"; then :; fi
  done
  printf '::endgroup::\n'
fi

if [[ -s "$credential_report" ]]; then
  # One row per (cloud, stack). The summary groups by cloud, because the fix is per cloud and
  # a list of forty stacks missing the same credential is one problem printed forty times.
  clouds="$(cut -f1 "$credential_report" | sort -u)"
  affected="$(wc -l <"$credential_report" | tr -d ' ')"

  tremvok::summary "## Terragrunt — a provider has no credential"
  tremvok::summary ""
  tremvok::summary "The state backend's credential is not the providers'. \`terragrunt-stack-env\` supplies the first; these stacks declare a provider whose own credential chain finds nothing on this runner."
  tremvok::summary ""
  while IFS= read -r cloud; do
    [[ -n "$cloud" ]] || continue
    remedy="$(awk -F'\t' -v c="$cloud" '$1 == c { print $4; exit }' "$credential_report")"
    count="$(awk -F'\t' -v c="$cloud" '$1 == c { n++ } END { print n + 0 }' "$credential_report")"
    tremvok::summary "### ${cloud} — ${count} stack(s)"
    tremvok::summary ""
    tremvok::summary "${remedy}"
    tremvok::summary ""
    awk -F'\t' -v c="$cloud" '$1 == c { printf "- `%s` (provider \"%s\")\n", $2, $3 }' "$credential_report" \
      | while IFS= read -r row; do tremvok::summary "$row"; done
    tremvok::summary ""
  done <<<"$clouds"

  if [[ "$TG_CREDENTIAL_PREFLIGHT" == "warn" ]]; then
    tremvok::warn "${affected} stack(s) declare a provider with no credential on this runner. terragrunt-credential-preflight is 'warn', so the plan runs anyway and will fail inside the provider."
  else
    tremvok::fail "${affected} stack(s) declare a provider with no credential on this runner. Planning them would fail inside the provider with an error naming a generated file rather than the credential. Fix the credential, or set terragrunt-credential-preflight: warn to plan anyway."
  fi
fi

# ── may this review spend an approval? ───────────────────────────────────────────────────
# True on the pull_request_review events that may apply: a review that was SUBMITTED (not edited
# or dismissed) and whose own state is approved. An empty field means the caller's action.yml
# did not pass it, which is evidence of nothing, so it counts as yes and the approval list
# decides alone. One definition, used by the apply decision further down and by the lock
# decision just below, because two copies of "may this run apply?" are how one of them ends up
# wrong. The reasoning for each half is with the apply decision.
review_spends_approval() {
  local action state
  action="$(printf '%s' "${EVENT_ACTION:-}" | tr '[:upper:]' '[:lower:]')"
  state="$(printf '%s' "${REVIEW_STATE:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$action" || "$action" == "submitted" ]] && [[ -z "$state" || "$state" == "approved" ]]
}

# ── does a plan take the state lock? ─────────────────────────────────────────────────────
# A plan writes nothing to state. The lock only buys it a wait for a concurrent apply to
# finish, so that it sees the final state. What the lock costs is a stranded one: the caller
# cancels a pull-request run whenever a newer push or review arrives, a cancelled tofu can be
# killed before it releases the lock, and every later run then waits out its lock timeout on
# that stack and fails, until somebody force-unlocks it by hand. That is not hypothetical: one
# plan cancelled 15 seconds after it took the lock on a single stack failed every pull request
# that planned that stack for hours.
#
# So `auto` takes no lock for the runs that never apply and that a newer event cancels:
#   pull_request                          plans and reports; the next push cancels it
#   pull_request_review, not approving    plans and reports; a comment is not an approval
# and keeps it for everything else. An approving review may apply, and callers are told never
# to cancel an apply, so its plan and its apply lock as they always did. push, schedule and
# workflow_dispatch are not cancelled by a newer event and may apply or report drift, so they
# keep the lock too. An apply always locks, whatever this says: that is what stops two applies
# writing at once.
#
# The price: a plan that reads state while another run is applying can show a diff that apply is
# halfway through making. It is a pull-request comment,
# redone on the next push, and never the plan that gets applied: an apply re-plans, or applies a
# saved plan that tofu itself refuses when the state has moved since.
case "$TG_PLAN_LOCK" in
  auto | always) ;;
  *) tremvok::fail "terragrunt-plan-lock must be auto or always (got '${TG_PLAN_LOCK}')" ;;
esac
plan_state_lock=true
if [[ "$TG_PLAN_LOCK" == "auto" ]]; then
  case "$EVENT_NAME" in
    pull_request) plan_state_lock=false ;;
    pull_request_review) review_spends_approval || plan_state_lock=false ;;
  esac
fi
if [[ "$plan_state_lock" == "false" ]]; then
  tremvok::log "plans on this ${EVENT_NAME} run take no state lock (terragrunt-plan-lock: ${TG_PLAN_LOCK}): it never applies, and a newer event cancels it"
fi

# ── plan every stack, continuing past failures ───────────────────────────────────────────
plan_failures=0
plan_changes=0
rows=""
details=""
# The stacks that get a plan excerpt in the comment, filled by the loop and rendered once the
# loop knows how many there are. Parallel arrays: bash 3.2 has no associative ones.
detail_stacks=()
detail_statuses=()
detail_files=()

for stack in "${stacks[@]}"; do
  out="${WORK_DIR}/plan/$(sanitize "$stack")"
  mkdir -p "$out"
  printf '::group::plan %s\n' "$stack"
  if tremvok::is_true "$DRY_RUN"; then
    printf 'no-changes\n' >"${out}/status"
    printf 'DRY RUN: terragrunt plan in %s\n' "$stack" >"${out}/plan.txt"
  else
    # Deliberately not `|| true`: the status file is the result, and the exit code is only
    # used to decide whether to print the tail of the log.
    set +e
    stack_env=()
    while IFS= read -r assignment; do
      [[ -n "$assignment" ]] && stack_env+=( "$assignment" )
    done < <(stack_env_for "$stack")
    env ${stack_env[@]+"${stack_env[@]}"} TG_STATE_LOCK="$plan_state_lock" \
      "${here}/terragrunt-run.sh" plan "$stack" "$out"
    code=$?
    set -e
  fi
  status="failed"
  [[ -f "${out}/status" ]] && status="$(<"${out}/status")"
  [[ "$status" == "failed" ]] && plan_failures=$(( plan_failures + 1 ))
  [[ "$status" == "changes" ]] && plan_changes=$(( plan_changes + 1 ))
  tremvok::log "PLAN ${stack} -> ${status}"
  if [[ "$status" == "failed" ]]; then
    for log in plan.txt init.txt; do
      [[ -s "${out}/${log}" ]] || continue
      printf -- '--- %s (tail) ---\n' "$log"
      "${here}/terragrunt-run.sh" redact "${out}/${log}" | tail -n 40
    done
  fi
  printf '::endgroup::\n'

  case "$status" in
    no-changes) badge='✅ no changes' ;;
    changes) badge='📝 changes' ;;
    *) badge='❌ failed' ;;
  esac
  summary_line="$(grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' "${out}/plan.txt" 2>/dev/null | tail -1 || true)"
  [[ -z "$summary_line" ]] && summary_line=$([[ "$status" == "no-changes" ]] && printf 'No changes' || printf 'see details')
  short="${stack#"${ROOT_DIR}"/}"
  rows+="| \`${short}\` | ${badge} | ${summary_line} |"$'\n'

  # A stack with no changes is fully described by its table row; an excerpt would only spend the
  # comment's size budget on "No changes." for every stack a module change reaches.
  if [[ "$status" != "no-changes" ]]; then
    detail_stacks+=("$short")
    detail_statuses+=("$status")
    detail_files+=("${out}/plan.txt")
  fi
done

# Terminal colour codes render as `[90m` noise in a comment, and each one costs six bytes of
# JSON escaping, so they come out before an excerpt is measured. Any CSI sequence, not just SGR.
strip_ansi() { LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"; }

build_details() { # excerpt-bytes
  local limit="$1" i excerpt out=""
  for ((i = 0; i < ${#detail_stacks[@]}; i++)); do
    if [[ -s "${detail_files[$i]}" ]]; then
      excerpt="$("${here}/terragrunt-run.sh" redact "${detail_files[$i]}" | strip_ansi | tail -c "$limit")"
    else
      excerpt='No plan output was produced; see the workflow run.'
    fi
    # Single quotes here are the printf format string; %s args expand as positional parameters
    # shellcheck disable=SC2016
    out+="$(printf '<details><summary><code>%s</code> — %s</summary>\n\n```text\n%s\n```\n</details>' "${detail_stacks[$i]}" "${detail_statuses[$i]}" "$excerpt")"$'\n'
  done
  printf '%s' "$out"
}

# Share COMMENT_BUDGET between the excerpts, after the table and the apply section have taken
# theirs, so a change that plans many stacks still posts a comment instead of one GitHub refuses.
# Each excerpt is the TAIL of its plan, which is where the summary and the last resources are.
# Below a useful size, excerpts are dropped for a pointer to the run rather than shrunk to noise.
excerpt_budget=0
if (( ${#detail_stacks[@]} > 0 )); then
  excerpt_budget=$(( (COMMENT_BUDGET - ${#rows} - 3000) / ${#detail_stacks[@]} - 200 ))
  if (( excerpt_budget > MAX_COMMENT_EXCERPT )); then excerpt_budget=$MAX_COMMENT_EXCERPT; fi
  if (( excerpt_budget >= 400 )); then
    details="$(build_details "$excerpt_budget")"
  else
    details="_Plan excerpts left out: ${#detail_stacks[@]} stacks with changes do not fit in one comment. The workflow run has every plan._"
  fi
fi

tremvok::summary "## Terragrunt plan"
tremvok::summary ""
tremvok::summary "| Stack | Result | Plan |"
tremvok::summary "|:--|:--|:--|"
tremvok::summary "$rows"

# ── which pull request authorises this run ───────────────────────────────────────────────
# A pull_request or pull_request_review carries the number in its event. A push does not, and
# the approval that authorises the apply belongs to the pull request the commit was merged
# from.
#
# All of it is behind `terragrunt-apply-on-merge`, which is off by default. Off, a push does
# not reach this block at all: no lookup, no approval read, plan only.
#
# After the plan on purpose: an unreadable answer is more useful with the plan already in the
# log, and the ordering leaves the plan comment one write, not two.
merged_pr=""
# Did this run consult the merged-pull-request path at all? Without it, "no merged pull
# request" would be said about a run that never asked.
merge_gate=false
# The lookup was made and could not be read. Separate from merge_lookup_failed below, which is
# only the subset of those that must fail the run: an unreadable answer still has to be
# reported as unreadable, and never as "this commit came from no merged pull request", which is
# the confusion the whole three-exit-code contract exists to prevent.
merge_lookup_unreadable=false
# Set instead of failing inline. See the report chain and the bottom of this file.
merge_lookup_failed=false
lookup_sha="${GITHUB_SHA:-$HEAD_SHA}"
if [[ -z "$PR_NUMBER" && "$EVENT_NAME" == "push" ]] && tremvok::is_true "$APPLY_ON_MERGE"; then
  merge_gate=true
  merged_pr_status=0
  # `|| merged_pr_status=$?` rather than a bare assignment: under `set -e` the assignment's
  # failure would kill the run, and the exit code is the whole signal. 0 found, 2 no merged
  # pull request, 1 unreadable, never collapsed.
  merged_pr="$(SHA="$lookup_sha" "$RESOLVE_MERGED_PR_BIN" 2>/dev/null)" \
    || merged_pr_status=$?
  case "$merged_pr_status" in
    0) tremvok::log "this commit was merged from pull request #${merged_pr}" ;;
    2) merged_pr="" ;;
    *)
      merged_pr=""
      merge_lookup_unreadable=true
      # A flag, NOT tremvok::fail. Failing here kills the run before the check run and the step
      # outputs are published, and a required check that never reports blocks the pull request
      # for ever. Enforced at the bottom of this file instead, beside the other refusal, once
      # everything is out.
      #
      # Not "before the plan comment": there is no comment to publish on this path. An
      # unreadable lookup leaves merged_pr empty, and this arm is only reached with PR_NUMBER
      # empty too, so gate_pr is empty and post_comment returns without posting. That is what
      # the `never`/`force` warning below means by "nowhere to go".
      #
      # Scoped to `auto` because that is the only mode whose decision depends on the answer,
      # and to a plan that has something outstanding, for the same reason the unreadable-review
      # -list refusal below is: refusing to apply nothing is not a refusal. The asymmetry the
      # earlier pass left here — reviews guarded on plan_changes, the lookup not — could not be
      # argued for. What is at stake is set by the plan, which this run has already made and
      # can read either way; whether the *reason* the approval is unknown is a missing number
      # or an unreadable review list does not change that a clean plan has nothing to apply,
      # and turning the default branch red on a transient API blip while the same run reports
      # "No changes to apply" is the contradiction that guard was added to remove.
      if [[ "$APPLY" != "auto" ]]; then
        tremvok::warn "could not read the pull requests for this commit; the plan comment has nowhere to go."
      elif (( plan_changes == 0 )); then
        # Still said out loud: a token missing `pull-requests: read` is a standing
        # misconfiguration, and it must not stay invisible until the first merge that changes
        # something. A warning, because nothing is outstanding.
        tremvok::warn "could not read the pull requests for ${lookup_sha}, so this run cannot tell whether the change was approved. Every affected stack planned clean, so there was nothing to apply and nothing is left outstanding."
      else
        merge_lookup_failed=true
        tremvok::error "could not read the pull requests for ${lookup_sha}, so this run cannot tell whether the change was approved."
      fi
      ;;
  esac
fi
gate_pr="${PR_NUMBER:-$merged_pr}"

# ── which events authorise an apply ──────────────────────────────────────────────────────
# The approval says the change may be applied; the event says an apply was asked for now. Only
# two events ask:
#
#   pull_request_review   the approval itself, which is what re-approving after a push sends
#   push                  the merged-push path, and only with terragrunt-apply-on-merge on:
#                         that is the only way merged_pr is non-empty above
#
# Everything else plans and reports, however the reviews read. Without this a plain
# `pull_request` run applies whatever the pull request already carried an approval for, so a
# push after an approval applies a commit nobody reviewed.
#
# EVENT_NAME is the value action.yml already passes from `github.event_name`, the same one
# resolve-mode.sh reads. Nothing here re-derives the event.
apply_authorised=false
if [[ "$EVENT_NAME" == "pull_request_review" ]]; then
  # The review's own state, so a COMMENTED or CHANGES_REQUESTED review on a pull request that
  # still holds an older approval re-plans rather than applying: that event is somebody
  # writing a comment, not somebody approving this commit. Empty means the payload field was
  # not passed at all, which is evidence of nothing, so the approval list decides alone.
  #
  # The event ACTION matters as much as the state, and this is the sharper edge. A workflow
  # that writes `on: pull_request_review:` with no `types:` filter subscribes to `edited` and
  # `dismissed` as well as `submitted`. An approving review that is merely EDITED, months
  # later, to fix a typo in its body, fires with action=edited and state=approved on whatever
  # HEAD is now. Without this, that edit applies a commit nobody reviewed, which is the exact
  # sequence the guard above exists to prevent.
  #
  # Empty means the field was not passed at all, which is evidence of nothing, so the approval
  # list decides alone. Both fields are lenient when absent for the same reason.
  if review_spends_approval; then
    apply_authorised=true
  fi
elif [[ -n "$merged_pr" ]]; then
  apply_authorised=true
fi

# ── decide whether this run may apply ────────────────────────────────────────────────────
approver_list=""
approval_readable=true
if [[ -n "$gate_pr" ]]; then
  # Captured to a variable first: `if ! x="$(cmd)"` keeps the command's exit status, which is
  # the whole point here. An unreadable review list must never look like "nobody approved" —
  # but it must not fail a run that was only ever going to plan either, so it is recorded and
  # enforced at the apply decision below.
  if approvers_raw="$(PR_NUMBER="$gate_pr" "${here}/approval-gate.sh" 2>/dev/null)"; then
    while IFS= read -r who; do
      [[ -n "$who" ]] && approver_list="${approver_list}@${who} "
    done <<<"$approvers_raw"
  else
    approval_readable=false
  fi
fi
approver_list="${approver_list% }"

may_apply=false
apply_reason=""
# An approval is standing on the pull request, but this run is not the event that spends it.
# Its own gate section and check-run title exist because "waiting for an independent approval"
# would be false here: there is one, and what is missing is an apply for THIS commit.
standing_approval=false
# Set only on the merged path, and that asymmetry is deliberate. On a pull request the
# action_required check already blocks the merge, so a red job on every API blip buys nothing;
# on a push nothing blocks, so refusing has to be loud or it is silence.
apply_refused=false
case "$APPLY" in
  never)
    apply_reason="apply is disabled for this run"
    ;;
  force)
    # An explicit apply skips the approval, so it needs its own authorisation. Anyone who can
    # approve a pull request can already merge it, which is why the approval path grants no new
    # power; forcing one does, so it is restricted to a named list and fails closed when that
    # list is empty rather than defaulting to "whoever pressed the button".
    actor_lc="$(printf '%s' "${GITHUB_ACTOR:-}" | tr '[:upper:]' '[:lower:]')"
    operators_lc="$(printf '%s' "$APPLY_OPERATORS" | tr ',' '\n' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${APPLY_OPERATORS//[[:space:]]/}" ]]; then
      tremvok::fail "terragrunt-apply: force needs terragrunt-apply-operators to list who may do it. Empty means nobody, so this run refuses rather than applying on the strength of a flag."
    elif ! printf '%s\n' "$operators_lc" | grep -Fxq "$actor_lc"; then
      tremvok::fail "${GITHUB_ACTOR:-this actor} is not in terragrunt-apply-operators, so cannot force an apply."
    fi
    may_apply=true
    apply_reason="applied by hand by @${GITHUB_ACTOR:-unknown}"
    ;;
  auto|*)
    if [[ -n "$approver_list" && "$apply_authorised" == true ]]; then
      may_apply=true
      if [[ -n "$merged_pr" ]]; then
        apply_reason="approved by ${approver_list} on #${merged_pr}"
      else
        apply_reason="approved by ${approver_list}"
      fi
    elif [[ -n "$approver_list" ]]; then
      # Reachable only with PR_NUMBER set: an approval needs a pull request in scope, and the
      # merged path is authorised by definition. So the check below lands on a head a merge is
      # waiting on, which is what makes `action_required` the right conclusion for it.
      standing_approval=true
      apply_reason="approved by ${approver_list}, but no apply has run for this commit"
    elif [[ "$approval_readable" == false ]]; then
      apply_reason="the reviews of #${gate_pr} could not be read, so this run refuses to apply"
      # Guarded on plan_changes, and that guard is the whole point. Refusing to apply nothing
      # is not a refusal: a merge where every stack plans clean has nothing at stake, and
      # failing it red on a transient reviews-API blip contradicts the same run's own comment
      # saying "Nothing to apply". The refusal exists to stop unapproved work being applied,
      # so it only fires when there was work.
      if [[ -n "$merged_pr" ]] && (( plan_changes > 0 )); then
        apply_refused=true
      fi
    elif [[ -n "$merged_pr" ]]; then
      apply_reason="#${merged_pr} was merged without an independent approval"
    elif [[ -n "$PR_NUMBER" ]]; then
      apply_reason="waiting for an independent approval"
    elif [[ "$merge_lookup_unreadable" == true ]]; then
      # Before the arm below, and the reason this flag exists separately from merge_gate: the
      # lookup was made and did not answer, so "came from no merged pull request" would be a
      # statement this run cannot make. It reaches the step summary and the warning above.
      apply_reason="the pull requests for ${lookup_sha} could not be read, so this run cannot tell whether the change was approved"
    elif [[ "$merge_gate" == true ]]; then
      apply_reason="this commit came from no merged pull request, so there was no approval to check"
    elif [[ "$EVENT_NAME" == "push" ]]; then
      # The default. Naming the input, because "no pull request is in scope" would send
      # somebody looking for a missing pull request rather than at the knob.
      apply_reason="terragrunt-apply-on-merge is off, so a push plans and applies nothing"
    else
      # A schedule's drift run, or any event with no pull request at all. There was never an
      # approval to read, and saying "no merged pull request" about it would be untrue.
      apply_reason="no pull request is in scope, so there was no approval to check"
    fi
    ;;
esac

if (( plan_failures > 0 )) && [[ "$may_apply" == true ]]; then
  may_apply=false
  apply_reason="${plan_failures} stack(s) failed to plan"
fi

# Gated on plan_changes so a clean plan says nothing. Warning about nothing outstanding is
# noise, and noise is how a warning stops being read.
if [[ "$may_apply" != true ]] && (( plan_changes > 0 )); then
  tremvok::summary ""
  tremvok::summary "**Not applied.** ${plan_changes} of ${#stacks[@]} stack(s) have pending changes — ${apply_reason}."
  if [[ -z "$PR_NUMBER" ]]; then
    tremvok::warn "${plan_changes} of ${#stacks[@]} stack(s) planned with changes and none were applied: ${apply_reason}."
  fi
fi

# ── the pull-request comment ─────────────────────────────────────────────────────────────
# Rendered against gate_pr, so a merge comments on the pull request it was merged from. One
# sticky comment keyed `<!-- tremvok:terragrunt -->`, edited in place by notify-pr.sh, so the
# merged pull request's plan comment gains the apply outcome rather than a second comment.
gate_section=""
if [[ -n "$gate_pr" ]]; then
  if [[ "$may_apply" == true ]]; then
    gate_section=$(printf '### Apply\n\n⏳ **%s — applying now.**\n\nThis section is rewritten when the run finishes.\n' "$apply_reason")
  elif (( plan_changes == 0 && plan_failures == 0 )); then
    gate_section=$(printf '### Apply\n\n✅ **Nothing to apply.** Every affected stack planned clean.\n')
  elif [[ "$apply_refused" == true ]]; then
    # shellcheck disable=SC2016  # Markdown backticks in printf format; not shell expressions
    gate_section=$(printf '### Apply\n\n❌ **%s.**\n\nNothing was applied. Retry the run, or check the token still has `pull-requests: read`.\n' "$(capitalize "$apply_reason")")
  elif [[ "$standing_approval" == true ]]; then
    # Deliberately not the "waiting for an approval" wording below: an approval is standing,
    # and saying it is not would send the reviewer to look for a review they already left.
    # shellcheck disable=SC2016  # Markdown backticks in printf format; not shell expressions
    gate_section=$(printf '### Apply\n\n✅ **Approved by %s, but no apply has run for this commit.**\n\nAn approval applies the commit it was given for, and this run is not that approval: it read one that was already standing. Dismiss the approval and re-approve to apply this commit now. `terragrunt-apply: force` applies it by hand instead, for an actor named in `terragrunt-apply-operators`.\n' "$approver_list")
  elif [[ -n "$merged_pr" ]]; then
    # shellcheck disable=SC2016  # Markdown backticks in printf format; not shell expressions
    gate_section=$(printf '### Apply\n\n⚠️ **%s, so the affected stacks were not applied.**\n\nThis is reported rather than failed: an unapproved merge is a branch-protection matter, not a broken build. The stacks stay unapplied until someone applies them, and the scheduled drift run keeps reporting them. Re-run with `terragrunt-apply: force` to apply them by hand.\n' "$(capitalize "$apply_reason")")
  else
    gate_section=$(printf '### Apply\n\n🔒 **%s.**\n\nApproving this pull request applies the stacks above — the run picks up the merge result, exactly what lands on the default branch — and the merge unblocks once it passes.\n' "$(capitalize "$apply_reason")")
  fi
fi

# A brace group redirected to a file, not `x="$( ... )"`. The last command inside a command
# substitution sets the substitution's exit status, so a false `[[ ]]` at the end makes the
# *assignment* fail, and under `set -e` that kills the run. `{ } > file` has no such trap.
#
# A function because the body is rendered twice: once before the apply and once after, so the
# comment never stays on "applying now" for ever.
render_comment() {
  {
    printf '## Terragrunt plan\n\n'
    printf '| Stack | Result | Plan |\n|:--|:--|:--|\n%s\n' "$rows"
    printf '%s\n' "$details"
    if [[ -n "$RUN_URL" ]]; then
      printf '\n_[Full output in the workflow run](%s); credential-shaped values are redacted._\n' "$RUN_URL"
    fi
    if [[ -n "$gate_section" ]]; then
      printf '\n%s\n' "$gate_section"
    fi
  } >"${WORK_DIR}/comment.md"
}

post_comment() {
  [[ -n "$gate_pr" ]] || return 0
  PR_NUMBER="$gate_pr" COMMENT_KEY="terragrunt" BODY_FILE="${WORK_DIR}/comment.md" \
    "${here}/notify-pr.sh" || tremvok::warn "the plan comment did not post."
}

render_comment
post_comment

# ── apply ────────────────────────────────────────────────────────────────────────────────
applied=false
apply_failures=0
failed_stacks=()

if [[ "$may_apply" == true ]]; then
  applied=true
  for stack in "${stacks[@]}"; do
    out="${WORK_DIR}/apply/$(sanitize "$stack")"
    mkdir -p "$out"
    printf '::group::apply %s\n' "$stack"
    if tremvok::is_true "$DRY_RUN"; then
      printf 'applied\n' >"${out}/status"
    else
      set +e
      # The plan run's directory, so apply picks up the plan file it wrote rather than
      # producing a second one. That is the whole return on collapsing this to one job: what
      # is applied is the diff that was reviewed, and when it has gone stale the run says so.
      stack_env=()
      while IFS= read -r assignment; do
        [[ -n "$assignment" ]] && stack_env+=( "$assignment" )
      done < <(stack_env_for "$stack")
      env ${stack_env[@]+"${stack_env[@]}"} \
        PLAN_DIR="${WORK_DIR}/plan/$(sanitize "$stack")" \
        "${here}/terragrunt-run.sh" apply "$stack" "$out"
      code=$?
      set -e
      if (( code != 0 )); then
        apply_failures=$(( apply_failures + 1 ))
        failed_stacks+=("${stack#"${ROOT_DIR}"/}")
        # The run buffers every invocation to a file, so without this a failed apply leaves an
        # empty log group and the reason nowhere at all.
        for log in apply.txt init.txt; do
          [[ -s "${out}/${log}" ]] || continue
          printf -- '--- %s (tail) ---\n' "$log"
          "${here}/terragrunt-run.sh" redact "${out}/${log}" | tail -n 40
        done
      fi
    fi
    printf '::endgroup::\n'
  done
fi

# Without this the comment is left saying "applying now" for ever, which is the one thing a
# rewritten gate section exists to prevent. No workflow link inside the section: the body
# already carries one a line above it, so an empty RUN_URL cannot render a dead link.
if [[ "$applied" == true && -n "$gate_pr" ]]; then
  if (( apply_failures == 0 )); then
    gate_section=$(printf '### Apply\n\n🚀 **Applied** — %s.\n' "$apply_reason")
  else
    gate_section=$(printf '### Apply\n\n❌ **Apply failed** — %s of %s stack(s): %s. %s.\n' "$apply_failures" "${#stacks[@]}" "${failed_stacks[*]}" "$apply_reason")
  fi
  render_comment
  post_comment
fi

# ── report ───────────────────────────────────────────────────────────────────────────────
# The arms below are in the SAME order as the gate_section arms above (applied, then clean,
# then refused, then the rest), so the check run and the pull-request comment can never say
# different things about one run. The two extra arms have no counterpart in gate_section
# because neither can coexist with a comment: a plan failure is reported in the rows, and an
# unreadable commit-to-pull-request lookup leaves gate_pr empty, so there is no thread to
# comment on.
if (( plan_failures > 0 )); then
  conclusion="failure"
  title="${plan_failures} stack(s) failed to plan"
  summary="Fix the plan before applying. The plan comment on this pull request has the redacted output."
elif [[ "$merge_lookup_failed" == true ]]; then
  # Set only when the plan had something outstanding, the same guard as apply_refused below,
  # so this arm and the "No changes to apply" arm further down can never both be true.
  conclusion="failure"
  title="Could not resolve the merged pull request"
  summary="The pull requests for ${lookup_sha} could not be read, so this run cannot tell which pull request authorised the merge, or whether it was approved. Nothing was applied."
elif [[ "$applied" == true && $apply_failures -gt 0 ]]; then
  conclusion="failure"
  title="${apply_failures} of ${#stacks[@]} stack(s) failed to apply"
  summary="Failed: ${failed_stacks[*]}. The run log has the redacted output for each."
elif [[ "$applied" == true ]]; then
  conclusion="success"
  title="Applied"
  summary="${#stacks[@]} stack(s) applied — ${apply_reason}."
  # "Safe to merge" is nonsense once the merge has happened.
  if [[ -n "$PR_NUMBER" ]]; then
    summary="${summary} Safe to merge."
  fi
elif (( plan_changes == 0 )); then
  # Before the refusal, exactly as gate_section puts "Nothing to apply" before it. An
  # unreadable review list on a run that would have applied nothing is not a failure, and
  # apply_refused is guarded on plan_changes so the two can never both be true here.
  conclusion="success"
  title="No changes to apply"
  summary="Every affected stack planned clean, so there is nothing to apply."
elif [[ "$apply_refused" == true ]]; then
  # On the merged path an unreadable review list has to be red: nothing blocks a merge that
  # has already happened, so a quiet skip leaves real changes unapplied with nobody told.
  conclusion="failure"
  title="Could not check the approval"
  summary="The reviews of #${merged_pr} could not be read, so this run cannot tell whether the merge was approved. Nothing was applied."
elif [[ "$standing_approval" == true ]]; then
  # Blocking, like the arm below and for the same reason: the pending changes are not applied
  # and the merge must wait for them. Only the title and the summary differ, because this
  # commit is not waiting on an approval, it is waiting on an apply.
  conclusion="action_required"
  title="Approved, but not applied for this commit"
  summary="${plan_changes} stack(s) have pending changes. #${gate_pr} carries an approval by ${approver_list}, but no apply has run for this commit: an approval applies the commit it was given for, and this run was not started by one. Dismiss the approval and re-approve to apply this commit now, or re-run with terragrunt-apply: force."
elif [[ -n "$PR_NUMBER" ]]; then
  # Not a failure and not a success: there is real work outstanding and a human has to
  # authorise it. `action_required` is the only conclusion that says so and still blocks.
  #
  # The predicate is PR_NUMBER, an open pull request in the event, rather than gate_pr: the
  # check is only a gate when it lands on a head a merge is waiting on.
  conclusion="action_required"
  title="Apply required before merge"
  summary="${plan_changes} stack(s) have pending changes — ${apply_reason}. This check turns green once they are applied."
elif tremvok::is_true "$APPLY_ON_MERGE"; then
  # No open pull request, so this check lands on a commit already on the branch and there is
  # no merge left to block. `neutral` records the outstanding work without turning the default
  # branch red, which is not what fixes an unapproved merge.
  #
  # Gated on the input, not on the event. `action_required` here is a blocking-shaped verdict
  # on a commit nothing is waiting on, so this is the better answer, but it is still a
  # different conclusion from the one a caller sees today. Somebody may be watching for it on
  # the drift cron. Callers who opt into the merged-apply path get the improvement; callers
  # who opt into nothing keep the conclusion they already have, which is the whole promise of
  # terragrunt-apply-on-merge defaulting to false.
  conclusion="neutral"
  title="Planned; not applied"
  summary="${plan_changes} of ${#stacks[@]} stack(s) have pending changes and none were applied — ${apply_reason}. Re-run with terragrunt-apply: force to apply them."
else
  conclusion="action_required"
  title="Apply required before merge"
  summary="${plan_changes} stack(s) have pending changes — ${apply_reason}. This check turns green once they are applied."
fi

CHECK_NAME="$CHECK_NAME" HEAD_SHA="$HEAD_SHA" CONCLUSION="$conclusion" TITLE="$title" \
  SUMMARY="$summary" DETAILS_URL="$RUN_URL" "${here}/publish-check.sh"

tremvok::set_output stacks "${#stacks[@]}"
tremvok::set_output plan-changes "$plan_changes"
tremvok::set_output plan-failures "$plan_failures"
tremvok::set_output applied "$applied"
tremvok::set_output apply-failures "$apply_failures"
tremvok::set_output deployed "$applied"
tremvok::set_output approvers "$approver_list"

(( plan_failures == 0 )) || tremvok::fail "${plan_failures} stack(s) failed to plan."
(( apply_failures == 0 )) || tremvok::fail "${apply_failures} of ${#stacks[@]} stack(s) failed to apply: ${failed_stacks[*]}"
# Last, so the check run, the plan comment and every step output are published before the run
# dies. Both of these are "the API could not be read", which must never be reported as
# "nobody approved", and only the merged path reaches either: on a pull request the
# action_required check already blocks the merge.
[[ "$merge_lookup_failed" != true ]] \
  || tremvok::fail "could not read the pull requests for ${lookup_sha}, so this run cannot tell which pull request authorised the merge, or whether it was approved. Nothing was applied."
[[ "$apply_refused" != true ]] \
  || tremvok::fail "could not read the reviews of #${merged_pr}, so this run refuses to apply ${plan_changes} stack(s) that may never have been approved."
