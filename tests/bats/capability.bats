#!/usr/bin/env bats
#
# The capability declaration. Everything named here is silent when it is wrong, which is the
# whole reason the declaration is validated at all rather than uploaded as found.
#
# What the MCP does with a broken document: it is read as PRIVATE and counted as unreadable,
# never named. So a tool whose JSON broke looks exactly like a tool that declared nothing,
# from the one side — the registry's — that could notice. The publishing side is where it can
# still be caught, and only if the deploy refuses.
#
# What it does with a document that parses and lies: `id` that is not a string is dropped, a
# non-string in `excludes` is dropped, `private` that is not exactly `false` is private. Each
# of those is a capability that quietly stops existing, or a tool that quietly stops being
# visible, with a green run behind it.
#
# And the mode gate, as for the docs corpus: one bucket, one key per repository, so a preview
# that published would overwrite the shared registry with an unmerged branch. Validation still
# runs there — a declaration only checked on `main` is checked after the merge that broke it.

load helper

setup() {
  setup_common
  cd "$WORK"

  export CLOUDFLARE_API_TOKEN=cf-token-value
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef
  export BUCKET=magmamoose-docs-index
  export REPO=tremvok
  export COMMIT=1c0ffee1c0ffee1c0ffee1c0ffee1c0ffee1c0ff
  export VISIBILITY=public
  export MODE=deploy
  export DRY_RUN=false

  export CAPABILITY_FILE=capability.json
  mkdir -p docs
  printf 'the page\n' >docs/cloudflare-docs.md
  declaration

  export UPLOADED="${WORK}/uploaded.json"
  export WRANGLER_BIN="${STUB_BIN}/wrangler"
  wrangler_ok
}

# The declaration under test. Valid as written; each test rewrites the one field it is about
# with `jq`, so no test restates the whole document and a new required field cannot be missed
# in nineteen copies of it.
declaration() {
  cat >"$CAPABILITY_FILE" <<'JSON'
{
  "schema": 1,
  "repo": "tremvok",
  "private": false,
  "file_issues_at": "MagmaMoose/tremvok",
  "action": { "uses": "magmamoose/tremvok@v2", "kind": "composite-action" },
  "capabilities": [
    {
      "id": "cloudflare-docs",
      "summary": "Build an MkDocs site strictly and publish it to Cloudflare Workers.",
      "ecosystems": ["python"],
      "inputs": ["cloudflare-docs-host"],
      "excludes": ["a docs site that is not MkDocs"],
      "doc": "docs/cloudflare-docs.md"
    }
  ]
}
JSON
}

# Rewrite the declaration through jq: `edit '.private = "false"'`.
edit() {
  jq "$1" "$CAPABILITY_FILE" >"${CAPABILITY_FILE}.tmp"
  mv "${CAPABILITY_FILE}.tmp" "$CAPABILITY_FILE"
}

# Records the call and keeps whatever was handed to `--file`, which is the only place the
# document that actually reaches the bucket can be inspected: it is a stamped copy, not the
# file in the tree.
wrangler_ok() {
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
while [ $# -gt 0 ]; do
  case "$1" in
    --file) cp "$2" "${UPLOADED}"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'Upload complete.\n'
exit 0
STUBEOF
}

run_publish() { run bash "${SCRIPTS}/publish-capability.sh"; }

uploaded() { jq -r "$1" "$UPLOADED"; }

@test "a deploy uploads the declaration to capability/<repo>.json" {
  run_publish
  [ "$status" -eq 0 ]
  calls | grep -Fq 'wrangler r2 object put magmamoose-docs-index/capability/tremvok.json'
  [ "$(output_value capability-declared)" = "true" ]
  [ "$(output_value capability-published)" = "true" ]
  [ "$(output_value capability-key)" = "capability/tremvok.json" ]
}

@test "the upload is --remote, so it reaches the bucket rather than local state" {
  run_publish
  [ "$status" -eq 0 ]
  calls | grep -Fq -- '--remote'
}

@test "the upload declares application/json" {
  run_publish
  [ "$status" -eq 0 ]
  calls | grep -Fq -- '--content-type application/json'
}

@test "the published document carries the commit and a timestamp the file cannot know" {
  run_publish
  [ "$status" -eq 0 ]
  [ "$(uploaded '.commit')" = "$COMMIT" ]
  [[ "$(uploaded '.generated')" == 20*T*Z ]]
  [ "$(uploaded '.capabilities[0].id')" = "cloudflare-docs" ]
}

@test "a public repository publishes the declaration it asked for" {
  run_publish
  [ "$status" -eq 0 ]
  [ "$(uploaded '.private')" = "false" ]
}

@test "a repository that is not public cannot publish a public declaration" {
  # The corpus rule, applied to the second document in the same bucket rather than reinvented:
  # only an explicit `public` is public, so `internal` and a typo are both private. The other
  # direction publishes an internal tool's declaration on a value nobody checked.
  export VISIBILITY=internal
  run_publish
  [ "$status" -eq 0 ]
  [ "$(uploaded '.private')" = "true" ]
  printf '%s\n' "$output" | grep -Fq 'asks to be public'
}

@test "an event carrying no repository object is private, not public" {
  export VISIBILITY=""
  run_publish
  [ "$status" -eq 0 ]
  [ "$(uploaded '.private')" = "true" ]
}

@test "a declaration that asks to stay private stays private on a public repository" {
  edit '.private = true'
  run_publish
  [ "$status" -eq 0 ]
  [ "$(uploaded '.private')" = "true" ]
}

@test "no declaration is not a failure, and is reported rather than passed over" {
  rm -f "$CAPABILITY_FILE"
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value capability-declared)" = "false" ]
  [ "$(output_value capability-published)" = "false" ]
  grep -Fq 'capability/tremvok.json' "$GITHUB_STEP_SUMMARY"
}

@test "an empty input publishes nothing at all" {
  export CAPABILITY_FILE=""
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value capability-published)" = "false" ]
}

@test "a preview validates and does not touch the shared registry" {
  export MODE=preview
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value capability-published)" = "false" ]
}

@test "a dry run does not touch the shared registry" {
  export DRY_RUN=true
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value capability-published)" = "false" ]
}

@test "a broken declaration fails the PULL REQUEST, not the merge that follows it" {
  # The point of validating outside the deploy path. Checked only on `main`, a malformed
  # declaration is checked after the merge that broke it: the pull request is green and the
  # run that finds out belongs to whoever merged next.
  export MODE=preview
  edit '.schema = 2'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq '`schema` must be the number 1'
}

@test "JSON that does not parse fails, naming the file and what jq said" {
  printf '{"schema": 1,\n' >"$CAPABILITY_FILE"
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'is not valid JSON'
  refute grep -Fq 'r2 object put' "$STUB_LOG"
}

@test "a declaration that is not an object fails rather than crashing the validator" {
  printf '[]' >"$CAPABILITY_FILE"
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'not a JSON object'
}

@test "private as the string \"false\" fails — the reader would hide the tool silently" {
  edit '.private = "false"'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq '`private` must be a JSON boolean'
}

@test "a declaration naming another repository fails — the key is this one" {
  edit '.repo = "brimyr"'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'capability/tremvok.json'
}

@test "an id that is not kebab-case fails — the reader drops the capability" {
  edit '.capabilities[0].id = "Patch Coverage"'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'must be kebab-case'
}

@test "a capability with no summary fails" {
  edit 'del(.capabilities[0].summary)'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq '.summary must be a non-empty string'
}

@test "a non-string inside excludes fails — the reader drops it without saying so" {
  edit '.capabilities[0].excludes = ["real", { "not": "a string" }]'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq '.excludes must be an array of strings'
}

@test "a doc that is a URL fails — the citation is built by concatenation" {
  edit '.capabilities[0].doc = "https://example.com/page"'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'repository-relative path'
}

@test "an action kind outside the enum fails" {
  edit '.action.kind = "plugin"'
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'action.kind` must be one of'
}

@test "every problem is reported at once, not one per attempt" {
  edit '.schema = 2 | .private = "false" | .capabilities[0].id = "Nope"'
  run_publish
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '::error::')" -ge 4 ]
}

@test "a capability with no excludes warns and still publishes" {
  # `excludes` is the load-bearing field: a capability that only says what it covers is
  # returned for cases it cannot serve, and the symptom is a check that passes having
  # measured nothing. It is not a schema violation, so it warns rather than refusing.
  edit 'del(.capabilities[0].excludes)'
  run_publish
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq '::warning::'
  printf '%s\n' "$output" | grep -Fq 'declares no `excludes`'
  calls | grep -Fq 'r2 object put'
}

@test "a doc naming a page this checkout does not have warns and still publishes" {
  rm -f docs/cloudflare-docs.md
  run_publish
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'not in this checkout'
  calls | grep -Fq 'r2 object put'
}

@test "the upload failing fails the step — a stale registry must not be green" {
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
printf 'A request to the Cloudflare API failed.\n' >&2
exit 1
STUBEOF
  run_publish
  [ "$status" -ne 0 ]
}

@test "a missing bucket is named, not guessed" {
  export BUCKET=""
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'cloudflare-docs-index-bucket'
}

@test "a missing API token is named, not guessed" {
  unset CLOUDFLARE_API_TOKEN
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'cloudflare-api-token'
}

@test "the API token never reaches the log or the step summary" {
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'cf-token-value' "$STUB_LOG"
  refute grep -Fq 'cf-token-value' "$GITHUB_STEP_SUMMARY"
}
