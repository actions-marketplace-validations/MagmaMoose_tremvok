#!/usr/bin/env bats
#
# The one that must never regress: a pull request must reach `wrangler versions upload
# --preview-alias`, never `wrangler deploy`. `deploy` puts the version onto the configured
# routes, so getting this wrong publishes an unreviewed branch to production and reports
# success while doing it. Everything else here is the same idea in smaller print — the flags
# only matter when they are wrong, so the assertions are on the exact command line.

load helper

setup() {
  setup_common
  cd "$WORK"
  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "$RUNNER_TEMP"

  export CLOUDFLARE_API_TOKEN=cf-token-value
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef

  # Off by default HERE, not in the action: most tests below assert on the exact argv of the
  # publish invocation, and the verifying dry run is a second invocation in front of it. The
  # tests that are about verification turn it on and assert on both calls.
  export VERIFY_CONFIG=false

  export ASSETS="${WORK}/dist"
  mkdir -p "$ASSETS"
  printf '<html></html>' >"${ASSETS}/index.html"

  # Recorder in front of Wrangler. Output is shaped like the real thing so the URL and
  # version-id parsing is exercised against text Wrangler actually prints, not a fixture
  # written to match the regex.
  export WRANGLER_BIN="${STUB_BIN}/wrangler"
  stub_script wrangler <<'STUBEOF'
#!/usr/bin/env bash
printf 'wrangler %s\n' "$*" >>"${STUB_LOG}"
# Argument boundaries survive here, and only here. `"$*"` above joins on spaces, so an empty
# trailing argument, a flag that gained a value, or a path containing a space are all
# invisible to a grep of that line. One record per argument, plus the count, is what makes
# `argv_count`/`argv_at` below able to see them.
{ printf '%s\n' "$#"; printf '%s\n' "$@"; } >>"${STUB_LOG}.argv"
case "$*" in
  *"--dry-run"*)
    # Shaped like Wrangler 4.114.0 and 4.127.1, colour codes and all. Wrangler colours its
    # warnings even when piped, and the step echoes the offending lines into the job log, so
    # they have to come out of it readable rather than as escape sequences.
    if [[ -n "${WRANGLER_DRY_RUN_WARNING:-}" ]]; then
      printf '\033[33m▲ \033[43;33m[\033[43;30mWARNING\033[43;33m]\033[0m \033[1mProcessing wrangler.toml configuration:\033[0m\n'
      printf '    - \033[2m%s\033[0m\n' "${WRANGLER_DRY_RUN_WARNING}"
    fi
    printf 'Your Worker has access to the following bindings:\n'
    printf 'Binding                        Resource\n'
    printf 'env.BURST (4 requests/10s)     Rate Limit\n'
    printf '--dry-run: exiting now.\n'
    exit "${WRANGLER_DRY_RUN_EXIT:-0}"
    ;;
  *"versions upload"*)
    printf 'Total Upload: 12.34 KiB / gzip: 4.56 KiB\n'
    printf 'Uploaded tremvok-site (2.34 sec)\n'
    printf 'Worker Version ID: 1a2b3c4d-5e6f-7890-abcd-ef1234567890\n'
    printf 'Version Preview URL: https://pr-1-worker.example.workers.dev\n'
    ;;
  *)
    printf 'Total Upload: 12.34 KiB / gzip: 4.56 KiB\n'
    printf 'Uploaded tremvok-site (2.34 sec)\n'
    printf 'Deployed tremvok-site triggers (0.50 sec)\n'
    printf '  https://tremvok-site.example.workers.dev\n'
    printf 'Current Version ID: aaaabbbb-cccc-dddd-eeee-ffff00001111\n'
    ;;
esac
exit "${WRANGLER_EXIT:-0}"
STUBEOF
}

# The last argument of the Wrangler invocation. A positional entry point is the only thing
# allowed to be there.
last_arg() { tail -1 "$STUB_LOG" | awk '{print $NF}'; }

# argv, recorded one argument per line with the count first, so assertions can see argument
# BOUNDARIES rather than a space-joined string. `awk '{print $NF}'` on a joined line silently
# skips a trailing empty field, which is exactly how an empty positional entry point (the
# hazard the adapter's own comment exists to prevent) hid from this suite.
argv_count() { head -1 "${STUB_LOG}.argv"; }
argv_at() { sed -n "$(( $1 + 1 ))p" "${STUB_LOG}.argv"; }
argv_last() { tail -n +2 "${STUB_LOG}.argv" | tail -1; }

@test "an assets-only Worker passes no argument after the flags at all" {
  # The regression that hid: `positional=( "$MAIN" )` instead of the guarded append sends
  # Wrangler a trailing EMPTY argument, which it reads as the entry script, meaning the
  # current directory. Every substring assertion in this file passes through that unchanged,
  # because a space-joined log line cannot show an empty final field. Assert the COUNT.
  MODE=deploy MAIN= run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(argv_count)" = "3" ]                      # deploy --assets <dir>
  [ "$(argv_last)" = "$ASSETS" ]
}

@test "an entry point is the last argument, and there is exactly one of it" {
  MODE=deploy MAIN=src/index.ts run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(argv_count)" = "4" ]
  [ "$(argv_last)" = "src/index.ts" ]
}

@test "minify is a boolean flag and never carries a value" {
  # `--minify true` would hand Wrangler a trailing positional it loads as the entry script:
  # the same leak as an empty positional, from a different line.
  MODE=deploy MINIFY=true run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(argv_count)" = "4" ]                      # deploy --assets <dir> --minify
  [ "$(argv_last)" = "--minify" ]
}

@test "a deploy never carries a preview alias" {
  # Asserted in both directions. The preview test proves the alias is present when it should
  # be; without this one, an alias leaking into a production deploy goes unnoticed.
  MODE=deploy PREVIEW_ALIAS=pr-9 run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  refute grep -q -- '--preview-alias' "$STUB_LOG"
}

@test "extra args reach Wrangler, before the entry point" {
  MODE=deploy EXTRA_ARGS='--keep-vars --old-asset-ttl 3600' MAIN=src/index.ts \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--keep-vars' "$STUB_LOG"
  grep -q -- '--old-asset-ttl 3600' "$STUB_LOG"
  [ "$(argv_last)" = "src/index.ts" ]
}

@test "a path containing a space stays one argument" {
  # Unquoted `--assets $ASSETS` splits it in two, and every space-free fixture in this file
  # would keep passing.
  spaced="${WORK}/my dist"
  mkdir -p "$spaced"; printf '<html></html>' >"${spaced}/index.html"
  MODE=deploy ASSETS="$spaced" run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(argv_count)" = "3" ]
  [ "$(argv_last)" = "$spaced" ]
}

@test "a push deploys to the live routes and never uploads a bare version" {
  MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -qE '^wrangler deploy( |$)' "$STUB_LOG"
  refute grep -q 'versions upload' "$STUB_LOG"
}

@test "a pull request uploads an aliased version and never touches production routes" {
  # `deploy` here would put the pull request straight onto the configured routes. The
  # uploaded version is reachable on its own alias URL and takes no production traffic.
  MODE=preview PREVIEW_ALIAS=pr-1 run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -q -- 'versions upload --preview-alias pr-1' "$STUB_LOG"
  refute grep -qE '^wrangler deploy( |$)' "$STUB_LOG"
}

@test "a preview without an alias is refused rather than uploaded unaliased" {
  MODE=preview run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"preview-alias"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a rollback is refused by name, because Wrangler rollback is not wired up here" {
  MODE=rollback run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cloudflare-workers"* ]]
  [[ "$output" == *"rollback"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "every override reaches the command line" {
  MODE=deploy CONFIG=wrangler.toml WORKER_NAME=tremvok-site CF_ENV=production \
    COMPATIBILITY_DATE=2025-01-01 MINIFY=true \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -q -- '--config wrangler.toml' "$STUB_LOG"
  grep -q -- '--name tremvok-site' "$STUB_LOG"
  grep -q -- '--env production' "$STUB_LOG"
  grep -q -- "--assets ${ASSETS}" "$STUB_LOG"
  grep -q -- '--compatibility-date 2025-01-01' "$STUB_LOG"
  grep -q -- '--minify' "$STUB_LOG"
}

@test "minify off means the flag is absent, not passed as false" {
  MODE=deploy MINIFY=false run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  refute grep -q -- '--minify' "$STUB_LOG"
}

@test "each line of cloudflare-vars becomes its own --var" {
  MODE=deploy VARS="$(printf 'API_BASE=https://api.example.com\nSTAGE=prod\n')" \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -o -- '--var' "$STUB_LOG" | wc -l | tr -d ' ')" -eq 2 ]
  grep -q -- '--var API_BASE=https://api.example.com' "$STUB_LOG"
  grep -q -- '--var STAGE=prod' "$STUB_LOG"
}

@test "the entry point is the last argument, after every flag" {
  MODE=deploy MAIN=src/index.ts run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(last_arg)" = "src/index.ts" ]
}

@test "an assets-only Worker passes no positional path at all" {
  # An empty positional would make Wrangler read the working directory as the script path.
  MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(last_arg)" = "$ASSETS" ]
}

@test "a missing api token fails before Wrangler is invoked" {
  CLOUDFLARE_API_TOKEN= MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cloudflare-api-token"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a missing account id fails before Wrangler is invoked" {
  CLOUDFLARE_ACCOUNT_ID= MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cloudflare-account-id"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "an artifact path that is not a directory is refused" {
  ASSETS="${WORK}/nope" MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "an empty artifact directory is refused before anything is published" {
  # Same failure the S3 target refuses: a build that quietly produced nothing, published
  # over a site that was serving.
  rm -rf "${ASSETS:?}"/*
  MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to publish"* ]]
  [[ "$output" == *"serving"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a directory holding only empty subdirectories is also refused" {
  rm -rf "${ASSETS:?}"/*
  mkdir -p "${ASSETS}/assets/img"
  MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "the build command runs before Wrangler" {
  stub tremvok-build 0 ''
  MODE=deploy BUILD_COMMAND=tremvok-build run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(head -1 "$STUB_LOG" | cut -d' ' -f1)" = "tremvok-build" ]
  grep -qE '^wrangler deploy( |$)' "$STUB_LOG"
}

@test "a build command that produces the assets runs before they are checked" {
  # `cloudflare-build-command` exists for a Worker that needs bundling, and bundling is what
  # creates the asset directory. Checking it first would refuse every Worker that builds.
  ASSETS="${WORK}/built" \
    BUILD_COMMAND="mkdir -p '${WORK}/built' && printf x >'${WORK}/built/index.html'" \
    MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--assets ${WORK}/built" "$STUB_LOG"
}

@test "a build that produces nothing is still refused" {
  ASSETS="${WORK}/built" BUILD_COMMAND="mkdir -p '${WORK}/built'" MODE=deploy \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to publish"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a failing build command stops the deploy" {
  stub tremvok-build 1 ''
  MODE=deploy BUILD_COMMAND=tremvok-build run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  refute grep -q '^wrangler' "$STUB_LOG"
}

@test "a failing Wrangler fails the step and reports nothing deployed" {
  WRANGLER_EXIT=1 MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [ "$(output_value deployed)" = "false" ]
}

@test "a dry run publishes nothing, and is Wrangler's own dry run rather than a log line" {
  MODE=deploy DRY_RUN=true run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
  grep -q '^wrangler deploy --dry-run --outdir ' "$STUB_LOG"
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(output_value deployed)" = "false" ]
}

@test "a dry run of a pull request never uploads a version either" {
  MODE=preview PREVIEW_ALIAS=pr-1 DRY_RUN=true run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
  grep -q '^wrangler deploy --dry-run ' "$STUB_LOG"
  refute grep -q 'versions upload' "$STUB_LOG"
}

@test "a dry run needs no credentials, so a fork or an unwired repository can still validate" {
  CLOUDFLARE_API_TOKEN= CLOUDFLARE_ACCOUNT_ID= MODE=deploy DRY_RUN=true \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  grep -q '^wrangler deploy --dry-run ' "$STUB_LOG"
}

@test "a dry run that does not bundle fails, and still publishes nothing" {
  WRANGLER_DRY_RUN_EXIT=1 MODE=deploy DRY_RUN=true run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not bundle"* ]]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
  [ "$(output_value deployed)" = "false" ]
}

# --- cloudflare-verify-config ---------------------------------------------------

@test "verification runs Wrangler's dry run before the deploy, never instead of it" {
  VERIFY_CONFIG=true MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "2" ]
  sed -n 1p "$STUB_LOG" | grep -q '^wrangler deploy --dry-run '
  sed -n 2p "$STUB_LOG" | grep -q '^wrangler deploy '
  [[ "$(sed -n 2p "$STUB_LOG")" != *"--dry-run"* ]]
  [ "$(output_value deployed)" = "true" ]
}

@test "a preview is verified with deploy --dry-run, then uploaded as a version" {
  VERIFY_CONFIG=true MODE=preview PREVIEW_ALIAS=pr-1 run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  sed -n 1p "$STUB_LOG" | grep -q '^wrangler deploy --dry-run '
  sed -n 2p "$STUB_LOG" | grep -q '^wrangler versions upload --preview-alias pr-1'
}

@test "an unexpected field stops the publish, even though Wrangler only warned" {
  # The silent case, verbatim from Wrangler: a misspelled section exits 0 and deploys a Worker
  # with no bucket. Only the warning says so.
  VERIFY_CONFIG=true MODE=deploy \
    WRANGLER_DRY_RUN_WARNING='Unexpected fields found in top-level field: "r2_bucket"' \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unexpected fields found in top-level field: "r2_bucket"'* ]]
  [[ "$output" == *"cloudflare-verify-config"* ]]
  # The lines echoed into ::error:: annotations are stripped of Wrangler's colour codes.
  [[ "$(printf '%s\n' "$output" | grep '^::error::' || true)" != *$'\033'* ]]

  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
  [ "$(output_value deployed)" = "false" ]
}

@test "a binding an --env deploy would not inherit stops the publish" {
  VERIFY_CONFIG=true MODE=deploy CF_ENV=staging \
    WRANGLER_DRY_RUN_WARNING='This is not what you probably want, since "r2_buckets" is not inherited by environments.' \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inherited by environments"* ]]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
}

@test "a warning that removes nothing does not stop the publish" {
  # Wrangler warns about a top-level deploy of a config with environments. Nothing it
  # declared goes missing, so it is not the failure this check exists for.
  VERIFY_CONFIG=true MODE=deploy \
    WRANGLER_DRY_RUN_WARNING='Multiple environments are defined in the Wrangler configuration file, but no target environment was specified for the deploy command.' \
    run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "2" ]
}

@test "with verification off, a deploy is exactly one Wrangler call" {
  VERIFY_CONFIG=false MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "1" ]
  refute grep -q -- '--dry-run' "$STUB_LOG"
}

@test "a missing token fails before the verifying dry run, not after a bundle" {
  CLOUDFLARE_API_TOKEN= VERIFY_CONFIG=true MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cloudflare-api-token"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "the preview url and version id are read out of Wrangler's output" {
  MODE=preview PREVIEW_ALIAS=pr-1 run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "true" ]
  [ "$(output_value url)" = "https://pr-1-worker.example.workers.dev" ]
  [ "$(output_value version-id)" = "1a2b3c4d-5e6f-7890-abcd-ef1234567890" ]
}

@test "a deploy reports the live url and its version id" {
  MODE=deploy run bash "${SCRIPTS}/deploy-cloudflare-workers.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value url)" = "https://tremvok-site.example.workers.dev" ]
  [ "$(output_value version-id)" = "aaaabbbb-cccc-dddd-eeee-ffff00001111" ]
}
