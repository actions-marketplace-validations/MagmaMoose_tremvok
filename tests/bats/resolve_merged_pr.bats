#!/usr/bin/env bats
#
# One thing is being protected here: three answers stay three answers. "found", "this commit
# came from no merged pull request" and "the API could not be read" have to be told apart, or
# an outage reads as "nobody approved" — which is either a silent skip of work that was
# approved, or an apply of work that never was.

load helper

setup() {
  setup_common
  cd "$WORK"
  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_API_URL=https://api.github.com
  export AUTH_TOKEN=ghs_test
  export SHA=deadbeefcafe

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
printf '%s' "${PULLS_JSON:-[]}"
exit "${CURL_EXIT:-0}"
STUBEOF
}

# stdout only, so "prints nothing" can actually be asserted: tremvok::fail writes to stderr.
resolve() { run bash -c "bash '${SCRIPTS}/resolve-merged-pr.sh' 2>/dev/null"; }

@test "a merged pull request prints its number and exits 0" {
  export PULLS_JSON='[{"number":123,"merged_at":"2026-08-18T10:00:00Z"}]'
  resolve
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "a commit whose pull requests are all open exits 2 and prints nothing, so an unmerged pull request cannot authorise an apply" {
  export PULLS_JSON='[{"number":7,"merged_at":null}]'
  resolve
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a curl failure exits 1 and prints nothing, so an unreadable API answer is never mistaken for 'no merged pull request'" {
  # That mistake is the whole reason this script exists: it turns an outage into either a
  # silent skip or an apply nobody approved.
  export CURL_EXIT=22
  resolve
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "exit 1 and exit 2 are different codes on the same empty stdout, which is the guard the whole change rests on" {
  export PULLS_JSON='[]'
  resolve
  none_status="$status"
  [ -z "$output" ]

  export CURL_EXIT=22
  resolve
  unreadable_status="$status"
  [ -z "$output" ]

  [ "$none_status" -eq 2 ]
  [ "$unreadable_status" -eq 1 ]
  [ "$none_status" -ne "$unreadable_status" ]
}

@test "several merged pull requests resolve by the stated tie-break and not by the order the API returned, so which approvals authorise the apply is never luck" {
  # Deliberately unhelpful order: in this payload and in the one below, the API hands back
  # the pull request that does NOT decide first. `first` with no sort answers 42 here and 41
  # below, so it is wrong both times and for a different reason each time.
  export PULLS_JSON='[{"number":42,"merged_at":"2026-08-19T10:00:00Z","base":{"ref":"release/1"}},{"number":41,"merged_at":"2026-08-18T10:00:00Z","base":{"ref":"release/1"}}]'
  export GITHUB_REF_NAME=main
  resolve
  [ "$status" -eq 0 ]
  # Rule 2: neither base matches the pushed branch, so the oldest merge wins.
  [ "$output" = "41" ]
}

@test "a merged pull request whose base is the pushed branch wins over an older merge into another branch, because that is the merge that put the commit here" {
  export PULLS_JSON='[{"number":41,"merged_at":"2026-08-18T10:00:00Z","base":{"ref":"release/1"}},{"number":42,"merged_at":"2026-08-19T10:00:00Z","base":{"ref":"main"}}]'
  export GITHUB_REF_NAME=main
  resolve
  [ "$status" -eq 0 ]
  # Rule 1 beats rule 2: 41 is the older merge, 42 is the one into this branch.
  [ "$output" = "42" ]
}

@test "with no branch to match on, the oldest merge still wins rather than the API's first element" {
  export PULLS_JSON='[{"number":42,"merged_at":"2026-08-19T10:00:00Z"},{"number":41,"merged_at":"2026-08-18T10:00:00Z"}]'
  export GITHUB_REF_NAME=
  resolve
  [ "$status" -eq 0 ]
  [ "$output" = "41" ]
}

@test "one transient failure does not turn a successful merge red: the lookup retries, the way every sibling GitHub call already does" {
  export PULLS_JSON='[{"number":123,"merged_at":"2026-08-18T10:00:00Z"}]'
  resolve
  [ "$status" -eq 0 ]
  grep -q -- '--retry 2' "$STUB_LOG"
}

@test "an open pull request alongside a merged one does not win, because merged_at is the test" {
  export PULLS_JSON='[{"number":9,"merged_at":null},{"number":42,"merged_at":"2026-08-19T10:00:00Z"}]'
  resolve
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "no sha anywhere fails rather than requesting /commits//pulls, which 404s and reads as 'no merged pull request'" {
  SHA= GITHUB_SHA= run bash "${SCRIPTS}/resolve-merged-pr.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs a commit sha"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "an HTTP error is exit 1 and never exit 2, because without --fail curl hands the error body to jq and 'unreadable' silently becomes 'no merged pull request'" {
  # The stub models what curl actually does with an HTTP error rather than grepping for the
  # flag: WITHOUT --fail curl prints the response body and exits 0, WITH it curl prints
  # nothing and exits 22. A 502 from a gateway in front of the API carries no JSON body at
  # all, and an empty body parses to no pull request — exit 2, the one answer an outage must
  # never produce.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
for arg in "$@"; do
  case "$arg" in
    --fail) exit 22 ;;
  esac
done
printf '%s' "${ERROR_BODY:-}"
exit 0
STUBEOF
  resolve
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q -- '--fail' "$STUB_LOG"
}

@test "a JSON error object in place of the list is exit 1 as well, so the other shape of HTTP error is not read as 'no merged pull request' either" {
  # GitHub answers 403 and 404 with an object, not a list. It has to reach the unreadable
  # path too: `.[]` over an object iterates its VALUES, and one of those parsing as a pull
  # request is a coincidence away from an apply nobody approved.
  #
  # This one passes with --fail deleted, because jq refuses the object and the run fails
  # closed by accident. The test above is the one that pins the flag; this is the second
  # shape, kept so a change to the jq filter cannot open the hole from the other side.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
for arg in "$@"; do
  case "$arg" in
    --fail) exit 22 ;;
  esac
done
printf '%s' '{"message":"Not Found","status":"404"}'
exit 0
STUBEOF
  resolve
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
