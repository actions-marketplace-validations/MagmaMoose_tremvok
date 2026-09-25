#!/usr/bin/env bats
#
# The scripts must run on the oldest bash a GitHub runner offers. `ubuntu-latest` has bash 5,
# but the macOS images still ship **bash 3.2** as /bin/bash — so a bash-4-only construct passes
# every test on Linux and fails with `bad substitution` on exactly one runner OS. That is a
# discovery you make in somebody's production deploy, which is why it is a test.

load helper
setup() { setup_common; }

@test "no script uses a bash 4+ parameter expansion or builtin" {
  # ${x,,} / ${x^} case modification, and mapfile/readarray, are all bash 4.
  run grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*[^}]*(,,|\^\^|\^)\}|^[^#]*\b(mapfile|readarray|declare -A)\b' \
    "${TREMVOK_ROOT}/scripts/lib/common.sh" \
    "${TREMVOK_ROOT}"/scripts/*.sh
  [ "$status" -ne 0 ]
}

@test "the scripts run under bash 3.2 when the host has one" {
  # macOS keeps 3.2 at /bin/bash; on Linux this is skipped rather than faked.
  version="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)"
  [ "$version" = "3" ] || skip "no bash 3.x at /bin/bash (found ${version}.x)"

  MODE=auto EVENT_NAME=pull_request PR_NUMBER=42 PREVIEW_ALIAS='Feature/Add Thing!' \
    run /bin/bash "${SCRIPTS}/resolve-mode.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value preview-alias)" = "feature-add-thing" ]
}

@test "is_true accepts every spelling GitHub Actions treats as true, under bash 3.2 too" {
  version="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)"
  shell=$([ "$version" = "3" ] && echo /bin/bash || command -v bash)

  for value in true TRUE True yes on 1; do
    run "$shell" -c "source '${SCRIPTS}/lib/common.sh'; tremvok::is_true '${value}'"
    [ "$status" -eq 0 ]
  done
  for value in false FALSE no off 0 "" maybe; do
    run "$shell" -c "source '${SCRIPTS}/lib/common.sh'; tremvok::is_true '${value}'"
    [ "$status" -ne 0 ]
  done
}

@test "a slug is URL-safe, collapsed and bounded" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; tremvok::slug 'Feature/Add  Thing!!'"
  [ "$output" = "feature-add-thing" ]

  run bash -c "source '${SCRIPTS}/lib/common.sh'; tremvok::slug '$(printf 'a%.0s' {1..100})'"
  [ "${#output}" -eq 60 ]
}

@test "multi-line step outputs survive, because name=value truncates at the first newline" {
  run bash -c "source '${SCRIPTS}/lib/common.sh'; tremvok::set_output plan 'line one
line two'"
  [ "$status" -eq 0 ]
  grep -q 'line two' "$GITHUB_OUTPUT"
  # The heredoc form, not `plan=line one`.
  refute grep -q '^plan=line one$' "$GITHUB_OUTPUT"
}
