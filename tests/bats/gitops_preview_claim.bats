#!/usr/bin/env bats
#
# Preview label claims against a curl stub that holds a small GitHub: open pull requests and
# their labels, label events, comments and label removals. What is pinned here is what an
# author relies on: the first pull request to take a label keeps it, a later one loses it again
# and is told who holds it, a refused claim is a green run, and only the holder releases.

load helper

L="deploy/preview-1"

setup() {
  setup_common
  export GITHUB_REPOSITORY=org/app
  export GITHUB_API_URL=https://api.example
  export AUTH_TOKEN=ghs_test
  export STATE="${WORK}/gh"
  mkdir -p "$STATE"
  echo '[]' >"${STATE}/pulls.json"
  echo '[]' >"${STATE}/events.json"
  echo '[]' >"${STATE}/comments.json"
  : >"${STATE}/writes.log"
  export LABELS=$'deploy/preview-1\ndeploy/preview-2'
  export URLS='{"deploy/preview-1": "https://preview-1.example.com"}'
  export EVENT_PATH="${WORK}/event.json"

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
# A little GitHub. Writes the response body to --output (or stdout), prints the status for
# --write-out, and honours --fail.
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
method=GET out="" data="" writeout="" fail=false url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --write-out) writeout="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --header|--max-time|--retry) shift 2 ;;
    --fail) fail=true; shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#"${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/"}"
query=""
case "$path" in *\?*) query="${path#*\?}"; path="${path%%\?*}" ;; esac
page="$(printf '&%s' "$query" | sed -n 's/.*&page=\([0-9]*\).*/\1/p')"
page="${page:-1}"
slice() { jq --argjson p "$page" '.[($p - 1) * 100:$p * 100]'; }
save() { mv "${STATE}/$1.new" "${STATE}/$1.json"; }
status=200 body='[]'
case "${method} ${path}" in
  "GET pulls")
    body="$(slice <"${STATE}/pulls.json")" ;;
  "GET issues/"*"/events")
    n="${path#issues/}"; n="${n%/events}"
    body="$(jq --argjson n "$n" '[.[] | select(.issue == $n) | del(.issue)]' "${STATE}/events.json" | slice)" ;;
  "GET issues/"*"/comments")
    n="${path#issues/}"; n="${n%/comments}"
    if [ -f "${STATE}/comments-down" ]; then status=503 body='{"message":"down"}'
    else body="$(jq --argjson n "$n" '[.[] | select(.issue == $n) | {id, body}]' "${STATE}/comments.json" | slice)"; fi ;;
  "POST issues/"*"/comments")
    n="${path#issues/}"; n="${n%/comments}"
    if [ -f "${STATE}/comments-down" ]; then status=503 body='{"message":"down"}'
    else
      jq --argjson n "$n" --slurpfile req "$data" '. + [{id: (length + 1), issue: $n, body: $req[0].body}]' \
        "${STATE}/comments.json" >"${STATE}/comments.new" && save comments
      echo "COMMENT ${n}" >>"${STATE}/writes.log"; status=201 body='{}'
    fi ;;
  "PATCH issues/comments/"*)
    id="${path#issues/comments/}"
    jq --argjson id "$id" --slurpfile req "$data" 'map(if .id == $id then .body = $req[0].body else . end)' \
      "${STATE}/comments.json" >"${STATE}/comments.new" && save comments
    echo "EDIT ${id}" >>"${STATE}/writes.log"; body='{}' ;;
  "DELETE issues/"*"/labels/"*)
    n="${path#issues/}"; n="${n%%/*}"; name="${path##*/labels/}"
    name="$(printf '%b' "${name//%/\\x}")"
    echo "UNLABEL ${n} ${name}" >>"${STATE}/writes.log"
    status="$(cat "${STATE}/unlabel-status" 2>/dev/null || echo 200)" ;;
  *)
    echo "stub: unexpected ${method} ${url}" >&2; status=599 body='{}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
[ -n "$writeout" ] && printf '%s' "$status"
if [ "$fail" = true ] && [ "$status" -ge 400 ]; then exit 22; fi
exit 0
STUBEOF
}

# open_pr NUMBER [LABEL...]: an open pull request carrying the labels.
open_pr() {
  local n="$1"
  shift
  jq --argjson n "$n" --args '. + [{number: $n, labels: ($ARGS.positional | map({name: .}))}]' "$@" \
    <"${STATE}/pulls.json" >"${STATE}/pulls.new"
  mv "${STATE}/pulls.new" "${STATE}/pulls.json"
}

# labelled NUMBER LABEL TIME ID: the event of LABEL going on pull request NUMBER.
labelled() {
  jq --argjson n "$1" --arg l "$2" --arg t "$3" --argjson id "$4" \
    '. + [{issue: $n, id: $id, event: "labeled", created_at: $t, label: {name: $l}}]' \
    "${STATE}/events.json" >"${STATE}/events.new"
  mv "${STATE}/events.new" "${STATE}/events.json"
}

# commented NUMBER STATE: the sticky comment an earlier run left for deploy/preview-1.
commented() {
  jq --argjson n "$1" --arg b "<!-- tremvok:gitops-preview-deploy-preview-1 -->"$'\n'"<!-- tremvok-claim:${2} -->"$'\n'"earlier" \
    '. + [{id: (length + 1), issue: $n, body: $b}]' "${STATE}/comments.json" >"${STATE}/comments.new"
  mv "${STATE}/comments.new" "${STATE}/comments.json"
}

# event ACTION NUMBER LABEL [CARRIED...]: the pull_request event payload. LABEL may be empty.
event() {
  local action="$1" n="$2" label="$3"
  shift 3
  jq -n --arg a "$action" --argjson n "$n" --arg l "$label" --args \
    '{action: $a, pull_request: {number: $n, labels: ($ARGS.positional | map({name: .}))}}
     + (if $l == "" then {} else {label: {name: $l}} end)' "$@" >"$EVENT_PATH"
}

claim() { run bash "${SCRIPTS}/gitops-preview-claim.sh"; }
comment_on() { jq -r --argjson n "$1" '[.[] | select(.issue == $n) | .body] | last // ""' "${STATE}/comments.json"; }
line_of() { grep -nx "$1" "${STATE}/writes.log" | head -n 1 | cut -d: -f1; }

@test "the first pull request to take a free label holds it, and is told where its preview is" {
  open_pr 15 "$L"
  event labeled 15 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = claimed ]
  comment_on 15 | grep -qF 'This pull request holds `deploy/preview-1`: https://preview-1.example.com'
  comment_on 15 | grep -qF '<!-- tremvok-claim:held -->'
  refute grep -q UNLABEL "${STATE}/writes.log"
}

@test "a second pull request that takes a held label loses it again, and is told who holds it" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-20T09:00:00Z 100
  labelled 15 "$L" 2026-10-23T10:00:00Z 200
  event labeled 15 "$L"
  claim
  # A refused claim is the job done, not a failure.
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = refused ]
  grep -qx "UNLABEL 15 ${L}" "${STATE}/writes.log"
  refute grep -q "UNLABEL 12" "${STATE}/writes.log"
  comment_on 15 | grep -qF '`deploy/preview-1` is in use by #12'
  comment_on 12 | grep -qF 'This pull request holds `deploy/preview-1`'
  # The refusal is written before the label comes off: the unlabeled run an App token's
  # removal starts reads it.
  [ "$(line_of 'COMMENT 15')" -lt "$(line_of "UNLABEL 15 ${L}")" ]
}

@test "two claims at once end the same in both runs: the earlier label event wins" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  # 15 took it first, although 12 is the older pull request.
  labelled 12 "$L" 2026-10-23T10:00:05Z 300
  labelled 15 "$L" 2026-10-23T10:00:01Z 200

  event labeled 12 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = refused ]
  grep -qx "UNLABEL 12 ${L}" "${STATE}/writes.log"

  : >"$GITHUB_OUTPUT"
  : >"${STATE}/writes.log"
  event labeled 15 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = claimed ]
  refute grep -q "UNLABEL 15" "${STATE}/writes.log"
}

@test "two label events in one second: the lower event id went on first, as a number" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-23T10:00:01Z 1000
  labelled 15 "$L" 2026-10-23T10:00:01Z 999
  event labeled 12 "$L"
  claim
  [ "$(output_value result)" = refused ]
  grep -qx "UNLABEL 12 ${L}" "${STATE}/writes.log"
}

@test "a label put back on ranks from when it went back, not from the first time" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 15 "$L" 2026-10-01T10:00:00Z 100
  labelled 12 "$L" 2026-10-20T10:00:00Z 200
  labelled 15 "$L" 2026-10-23T10:00:00Z 300
  event labeled 15 "$L"
  claim
  [ "$(output_value result)" = refused ]
}

@test "a holder past the first page of open pull requests still holds" {
  jq -n '[range(200; 300) | {number: ., labels: []}]' >"${STATE}/pulls.json"
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-20T09:00:00Z 100
  labelled 15 "$L" 2026-10-23T10:00:00Z 200
  event labeled 15 "$L"
  claim
  [ "$(output_value result)" = refused ]
}

@test "a label event past the first page of events still counts" {
  jq -n '[range(0; 100) | {issue: 12, id: ., event: "mentioned", created_at: "2026-10-19T00:00:00Z"}]' \
    >"${STATE}/events.json"
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-20T09:00:00Z 500
  labelled 15 "$L" 2026-10-23T10:00:00Z 600
  event labeled 15 "$L"
  claim
  [ "$(output_value result)" = refused ]
  [[ "$output" != *"ranks last"* ]]
}

@test "a claim with no label event to show for it ranks after one that has" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 15 "$L" 2026-10-23T10:00:00Z 300
  event labeled 15 "$L"
  claim
  [ "$(output_value result)" = claimed ]
  grep -qx "UNLABEL 12 ${L}" "${STATE}/writes.log"
  [[ "$output" == *"ranks last"* ]]
}

@test "taking the label off the holder releases it, in the same comment" {
  commented 12 held
  event unlabeled 12 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = released ]
  comment_on 12 | grep -qF '`deploy/preview-1` was released'
  grep -qx 'EDIT 1' "${STATE}/writes.log"
  refute grep -q 'COMMENT 12' "${STATE}/writes.log"
}

@test "when the holder lets go, a pull request still carrying the label is told it holds it" {
  open_pr 12
  open_pr 15 "$L"
  commented 12 held
  event unlabeled 12 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = released ]
  comment_on 12 | grep -qF '`deploy/preview-1` was released'
  comment_on 15 | grep -qF '<!-- tremvok-claim:held -->'
  refute grep -q UNLABEL "${STATE}/writes.log"
}

@test "a refused label taken off by an App token does not tell that pull request it released anything" {
  open_pr 12 "$L"
  commented 15 refused
  event unlabeled 15 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = ignored ]
  comment_on 15 | grep -qF '<!-- tremvok-claim:refused -->'
  refute grep -q 'was released' "${STATE}/comments.json"
}

@test "closing the holder releases it and takes the label off, so reopening it takes nothing back" {
  commented 12 held
  event closed 12 "" "$L" bug
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = released ]
  comment_on 12 | grep -qF 'was released'
  grep -qx "UNLABEL 12 ${L}" "${STATE}/writes.log"
  refute grep -q 'UNLABEL 12 bug' "${STATE}/writes.log"
  [ "$(line_of 'EDIT 1')" -lt "$(line_of "UNLABEL 12 ${L}")" ]
}

@test "a label that is not a preview label changes nothing" {
  event labeled 15 bug
  claim
  [ "$status" -eq 0 ]
  [ "$(output_value result)" = ignored ]
  [ ! -s "$STUB_LOG" ]
}

@test "a label with a space in it is one label, not two" {
  open_pr 15 'preview one'
  event labeled 15 'preview one'
  LABELS='preview one' URLS= claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = claimed ]
}

@test "a comment that cannot be posted does not fail the run" {
  open_pr 15 "$L"
  touch "${STATE}/comments-down"
  event labeled 15 "$L"
  claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = claimed ]
  [[ "$output" == *"::warning::"* ]]
}

@test "a refused label that cannot be taken off fails the run: the controller would still deploy it" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-20T09:00:00Z 100
  labelled 15 "$L" 2026-10-23T10:00:00Z 200
  echo 403 >"${STATE}/unlabel-status"
  event labeled 15 "$L"
  claim
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not take deploy/preview-1 off #15 (HTTP 403)"* ]]
}

@test "a dry run reads and reports, and writes nothing" {
  open_pr 12 "$L"
  open_pr 15 "$L"
  labelled 12 "$L" 2026-10-20T09:00:00Z 100
  labelled 15 "$L" 2026-10-23T10:00:00Z 200
  event labeled 15 "$L"
  DRY_RUN=true claim
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value result)" = refused ]
  [ ! -s "${STATE}/writes.log" ]
}

@test "a URL for a label that is not a preview label, and an event with no pull request, are refused" {
  event labeled 15 "$L"
  URLS='{"deploy/preview-9": "https://preview-9.example.com"}' claim
  [ "$status" -eq 1 ]
  [[ "$output" == *"deploy/preview-9 is not one of gitops-preview-labels"* ]]

  echo '{"action": "labeled"}' >"$EVENT_PATH"
  claim
  [ "$status" -eq 1 ]
  [[ "$output" == *"carries no pull request"* ]]
}
