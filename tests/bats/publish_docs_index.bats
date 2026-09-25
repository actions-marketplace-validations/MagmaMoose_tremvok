#!/usr/bin/env bats
#
# The corpus upload. Two things here must never regress, and both are silent when wrong.
#
# `--remote`: without it Wrangler 4 writes to the LOCAL miniflare simulation under
# .wrangler/state and exits 0. Green step, real file on disk, empty bucket — and the only
# symptom is an MCP search returning last week's docs, days later, in someone else's agent.
#
# The mode gate: there is one bucket and one key per repository, so a preview that published
# would overwrite the shared corpus with an unmerged branch. Same shape as `cloudflare-docs`
# publishing no site on a preview: the corpus has no preview destination either.

load helper

setup() {
  setup_common
  cd "$WORK"

  export CLOUDFLARE_API_TOKEN=cf-token-value
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef
  export BUCKET=magmamoose-docs-index
  export REPO=tremvok
  export MODE=deploy
  export DRY_RUN=false

  export INDEX_FILE="${WORK}/index/tremvok.json"
  mkdir -p "${WORK}/index"
  printf '{"repo":"tremvok","entries":[]}' >"$INDEX_FILE"

  export WRANGLER_BIN="${STUB_BIN}/wrangler"
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
{ printf '%s\n' "$#"; printf '%s\n' "$@"; } >>"${STUB_LOG}.argv"
printf 'Creating object "index/tremvok.json" in bucket "magmamoose-docs-index".\n'
printf 'Upload complete.\n'
exit 0
STUBEOF
}

run_publish() { run bash "${SCRIPTS}/publish-docs-index.sh"; }

@test "a deploy uploads the index to index/<repo>.json" {
  run_publish
  [ "$status" -eq 0 ]
  calls | grep -Fq 'wrangler r2 object put magmamoose-docs-index/index/tremvok.json'
  [ "$(output_value index-published)" = "true" ]
  [ "$(output_value index-key)" = "index/tremvok.json" ]
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

@test "a preview does not touch the shared corpus" {
  export MODE=preview
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value index-published)" = "false" ]
}

@test "a dry run does not touch the shared corpus" {
  export DRY_RUN=true
  run_publish
  [ "$status" -eq 0 ]
  refute grep -Fq 'r2 object put' "$STUB_LOG"
  [ "$(output_value index-published)" = "false" ]
}

@test "a missing index file fails rather than publishing nothing" {
  rm -f "$INDEX_FILE"
  run_publish
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'was not generated'
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

@test "the upload failing fails the step — a stale corpus must not be green" {
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
printf 'A request to the Cloudflare API failed.\n' >&2
exit 1
STUBEOF
  run_publish
  [ "$status" -ne 0 ]
}
