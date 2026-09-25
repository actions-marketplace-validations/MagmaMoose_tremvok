#!/usr/bin/env bats
#
# The cloudflare-docs adapter. Two things here are not shared with `cloudflare-workers` and
# both are easy to get wrong in the direction that publishes something:
#
#   * A pull request must publish NOTHING. These Workers have `workers_dev = false` and no
#     route, so `versions upload --preview-alias` has nowhere to serve a preview from — there
#     is no disposable destination, only the live one.
#   * An empty site directory must be refused. Publishing nothing over a site that is
#     currently serving SUCCEEDS, which is the same failure `aws s3 sync --delete` has.

load helper

setup() {
  setup_common
  cd "$WORK"

  export CLOUDFLARE_API_TOKEN=cf-token-value
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef
  export MODE=deploy
  export DRY_RUN=false
  export SITE_DIR="${WORK}/site"
  export DOCS_HOST=docs.magmamoose.com
  export DOCS_PATH=tremvok

  mkdir -p "$SITE_DIR"
  printf '<html></html>' >"${SITE_DIR}/index.html"

  export WRANGLER_BIN="${STUB_BIN}/wrangler"
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
{ printf '%s\n' "$#"; printf '%s\n' "$@"; } >>"${STUB_LOG}.argv"
printf 'Total Upload: 12.34 KiB / gzip: 4.56 KiB\n'
printf 'Uploaded docs-tremvok (2.34 sec)\n'
exit 0
STUBEOF
}

run_deploy() { run bash "${SCRIPTS}/deploy-cloudflare-docs.sh"; }

@test "a deploy runs wrangler deploy" {
  run_deploy
  [ "$status" -eq 0 ]
  calls | grep -Fq 'wrangler deploy'
  [ "$(output_value deployed)" = "true" ]
}

@test "the reported URL is the router's address, not a workers.dev one" {
  run_deploy
  [ "$status" -eq 0 ]
  [ "$(output_value url)" = "https://docs.magmamoose.com/tremvok/" ]
}

@test "the reported URL keeps its trailing slash" {
  # `/tremvok` and `/tremvok/` are different requests to an assets router: the first 404s
  # where the second serves index.html.
  export DOCS_PATH=tremvok/
  run_deploy
  [ "$(output_value url)" = "https://docs.magmamoose.com/tremvok/" ]
}

@test "a pull request publishes nothing — there is no preview destination" {
  export MODE=preview
  run_deploy
  [ "$status" -eq 0 ]
  refute grep -Fq 'wrangler' "$STUB_LOG"
  [ "$(output_value deployed)" = "false" ]
  printf '%s\n' "$output" | grep -Fq 'workers_dev is false by design'
}

@test "a preview never reaches versions upload either" {
  export MODE=preview
  run_deploy
  refute grep -Fq 'versions upload' "$STUB_LOG"
}

@test "a dry run publishes nothing" {
  export DRY_RUN=true
  run_deploy
  [ "$status" -eq 0 ]
  refute grep -Fq 'wrangler' "$STUB_LOG"
  [ "$(output_value deployed)" = "false" ]
}

@test "a pull request with no secrets still builds and checks" {
  # Dependabot pull requests carry no repository secrets, so CLOUDFLARE_API_TOKEN and
  # CLOUDFLARE_ACCOUNT_ID arrive EMPTY. Nothing before the early return above touches
  # Cloudflare, so demanding them at the top of the script failed every dependency bump on a
  # target the bump could not have reached — `CLOUDFLARE_API_TOKEN is required` on a run whose
  # own log then says it publishes nothing.
  export MODE=preview
  unset CLOUDFLARE_API_TOKEN
  unset CLOUDFLARE_ACCOUNT_ID
  run_deploy
  [ "$status" -eq 0 ]
  refute grep -Fq 'wrangler' "$STUB_LOG"
  [ "$(output_value deployed)" = "false" ]
}

@test "a dry run with no secrets still builds and checks" {
  export DRY_RUN=true
  unset CLOUDFLARE_API_TOKEN
  unset CLOUDFLARE_ACCOUNT_ID
  run_deploy
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "false" ]
}

@test "an empty site directory is refused even with no secrets" {
  # The build IS the check on a pull request, so the guard that catches a --strict build
  # producing nothing has to keep firing when there are no credentials to reach. Moving the
  # credential check down must not take this guard with it.
  export MODE=preview
  unset CLOUDFLARE_API_TOKEN
  unset CLOUDFLARE_ACCOUNT_ID
  rm -f "${SITE_DIR}/index.html"
  run_deploy
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'Refusing to publish an empty site'
}

@test "an empty site directory is refused" {
  rm -f "${SITE_DIR}/index.html"
  run_deploy
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'Refusing to publish an empty site'
  refute grep -Fq 'wrangler' "$STUB_LOG"
}

@test "a missing site directory is refused" {
  rm -rf "$SITE_DIR"
  run_deploy
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'Nothing was built'
}

@test "a missing API token is named, not guessed" {
  # MODE=deploy from setup(), which is the point: a run that WILL publish still refuses
  # without credentials. Only the runs that publish nothing were let through.
  unset CLOUDFLARE_API_TOKEN
  run_deploy
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'cloudflare-api-token'
}

@test "the wrangler config path is passed through when set" {
  export CONFIG=docs/wrangler.toml
  run_deploy
  [ "$status" -eq 0 ]
  calls | grep -Fq -- '--config docs/wrangler.toml'
}

@test "the worker name override reaches wrangler" {
  export WORKER_NAME=docs-tremvok
  run_deploy
  calls | grep -Fq -- '--name docs-tremvok'
}

@test "publishing without a host warns rather than reporting a wrong URL" {
  export DOCS_HOST=""
  run_deploy
  [ "$status" -eq 0 ]
  [ "$(output_value url)" = "" ]
  printf '%s\n' "$output" | grep -Fq 'no URL can be reported'
}
