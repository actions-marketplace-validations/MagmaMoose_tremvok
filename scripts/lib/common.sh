#!/usr/bin/env bash
# Shared helpers. Sourced, never executed.
#
# Every script here runs under `set -euo pipefail`, which is the whole point: an earlier
# frontend-deploy workflow this action replaces "reported success" on an auth failure, because
# `wrangler … | tee log` reports *tee's* exit code. The same trap exists verbatim with
# `aws s3 sync … | tee`, so the rule in this repo is that nothing is piped into `tee` without
# `pipefail` set — and these helpers assume it.

# GitHub renders ::notice/::warning/::error in the log and the annotations panel. Plain echo
# is invisible in the summary view, which is where a skip most needs to be readable.
tremvok::log() { printf '%s\n' "$*"; }
tremvok::notice() { printf '::notice::%s\n' "$*"; }
tremvok::warn() { printf '::warning::%s\n' "$*"; }
tremvok::error() { printf '::error::%s\n' "$*" >&2; }

tremvok::fail() {
  tremvok::error "$*"
  exit 1
}

# Writes a step output. Multi-line values go through the heredoc form because the `name=value`
# form silently truncates at the first newline — a preview URL list or a plan excerpt would
# arrive as its first line and nothing would look wrong.
tremvok::set_output() {
  local name="$1" value="${2-}"
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  if [[ "$value" == *$'\n'* ]]; then
    local delimiter="tremvok-$(( RANDOM * RANDOM ))"
    {
      printf '%s<<%s\n' "$name" "$delimiter"
      printf '%s\n' "$value"
      printf '%s\n' "$delimiter"
    } >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  fi
}

tremvok::summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
}

tremvok::require() {
  local name="$1" hint="${2-}"
  [[ -n "${!name:-}" ]] || tremvok::fail "${name} is required${hint:+ — ${hint}}"
}

# A pull-request number ends up as a path segment in a GitHub API URL, so it is digits or it
# is refused. A `case` glob rather than `[[ =~ ]]`, for the same reason `tr` is used instead of
# bash 4 case modification below: the macOS runners ship bash 3.2.
tremvok::require_pr_number() { # input-name value
  case "${2-}" in
    '' | *[!0-9]*)
      tremvok::fail "${1}: '${2-}' is not a pull-request number. Digits only, e.g. 1234."
      ;;
  esac
}

# Retries a command with a fixed delay. Deliberately not exponential: the things retried here
# (a CDN edge picking up an invalidation, a Lambda alias settling) resolve on a wall-clock
# schedule, so backing off just means noticing later.
tremvok::retry() {
  local attempts="$1" delay="$2"
  shift 2
  local attempt=1
  until "$@"; do
    if (( attempt >= attempts )); then
      return 1
    fi
    tremvok::log "  attempt ${attempt}/${attempts} failed; retrying in ${delay}s"
    attempt=$(( attempt + 1 ))
    sleep "$delay"
  done
  return 0
}

# JSON-encodes one string. `jq -Rn` rather than hand-rolled escaping, because the values here
# are commit messages and branch names and one unescaped quote turns a notification payload
# into a 400 that the failure-isolated caller reports as a bare "false".
tremvok::json_string() { jq -Rn --arg value "$1" '$value'; }

# `true` for exactly the strings GitHub Actions treats as true. An input of "TRUE" or "yes"
# reading as false is a class of bug that only shows up in production.
#
# `tr` rather than `${1,,}`: that expansion is bash 4, and GitHub's macOS runners still ship
# bash 3.2 as /bin/bash. Nothing in this repository may use a bash-4-only construct —
# `tests/bats/portability.bats` enforces it, because the failure mode is a `bad substitution`
# on one runner OS and a passing suite everywhere else.
tremvok::is_true() {
  case "$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# A URL-safe, stable preview slug. Cloudflare aliases and S3 key prefixes both reject or
# mangle characters that branch names allow, and an alias that changes on every push defeats
# the point of a sticky preview URL.
tremvok::slug() {
  local raw
  raw="$(printf '%s' "${1-}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "$(printf '%s' "$raw" | cut -c1-60)"
}

# Is tag $1 newer than tag $2? SemVer precedence when both end in MAJOR.MINOR.PATCH with an
# optional -PRERELEASE and share the prefix before it (`v`, `core-v`): 1.2.3 is newer than
# 1.2.3-rc.1, rc.10 is newer than rc.9, and a numeric identifier ranks below an alphanumeric
# one. Anything else falls back to `sort -V`.
#
# `sort -V` alone gets the one comparison a promotion makes backwards: it puts 1.2.3 BEFORE
# 1.2.3-rc.1. An overlay running a release candidate would then refuse the candidate's own
# stable release as a downgrade.
tremvok::version_gt() {
  local a="${1-}" b="${2-}"
  [[ "$a" != "$b" ]] || return 1
  local core='([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?$'
  local pa pb a1 a2 a3 apre b1 b2 b3 bpre
  if [[ "$a" =~ $core ]]; then
    pa="${a%"${BASH_REMATCH[0]}"}"; a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"
    a3="${BASH_REMATCH[3]}"; apre="${BASH_REMATCH[5]}"
    if [[ "$b" =~ $core ]]; then
      pb="${b%"${BASH_REMATCH[0]}"}"; b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"
      b3="${BASH_REMATCH[3]}"; bpre="${BASH_REMATCH[5]}"
      if [[ "$pa" == "$pb" ]]; then
        if ((10#$a1 != 10#$b1)); then ((10#$a1 > 10#$b1)); return; fi
        if ((10#$a2 != 10#$b2)); then ((10#$a2 > 10#$b2)); return; fi
        if ((10#$a3 != 10#$b3)); then ((10#$a3 > 10#$b3)); return; fi
        # Same version: a release outranks its own prereleases.
        if [[ -z "$apre" && -z "$bpre" ]]; then return 1; fi
        if [[ -z "$apre" ]]; then return 0; fi
        if [[ -z "$bpre" ]]; then return 1; fi
        local IFS=. LC_ALL=C i x y
        local -a ia ib
        read -r -a ia <<<"$apre"
        read -r -a ib <<<"$bpre"
        for ((i = 0; ; i++)); do
          if ((i >= ${#ia[@]} && i >= ${#ib[@]})); then return 1; fi
          if ((i >= ${#ia[@]})); then return 1; fi
          if ((i >= ${#ib[@]})); then return 0; fi
          x="${ia[$i]}"; y="${ib[$i]}"
          [[ "$x" != "$y" ]] || continue
          if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then ((10#$x > 10#$y)); return; fi
          if [[ "$x" =~ ^[0-9]+$ ]]; then return 1; fi
          if [[ "$y" =~ ^[0-9]+$ ]]; then return 0; fi
          [[ "$x" > "$y" ]]; return
        done
      fi
    fi
  fi
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" == "$a" ]]
}
