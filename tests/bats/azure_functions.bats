#!/usr/bin/env bats
#
# The two that must never regress, both of which were found the hard way:
#
#   * `az functionapp deployment source config-zip` prints "Operation returned an invalid
#     status 'Bad Request'" and exits NON-ZERO over a deploy that actually succeeded. Failing
#     on that exit code fails green deploys; trusting it hides real ones. The script asks the
#     platform instead, and these tests pin both directions.
#   * A package whose contents are nested one directory down, or built by a glob that skipped
#     dotfiles, deploys cleanly and then serves NOTHING. There is no error to notice, so the
#     guard is the only thing between that zip and a silent 404 on every route.

load helper

setup() {
  setup_common
  cd "$WORK"
  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "$RUNNER_TEMP"

  export APP_NAME=ghreceiver
  export RESOURCE_GROUP=rg-webhooks
  export ARTIFACT_PATH="${WORK}/package.zip"
  export READY_DELAY=0
  export READY_ATTEMPTS=3

  # A file is all the script needs from the artifact itself; the LAYOUT comes from the unzip
  # stub, so a test can describe a package shape without having to build one.
  printf 'not really a zip, and it does not need to be\n' >"$ARTIFACT_PATH"

  export UNZIP_BIN="${STUB_BIN}/unzip"
  export ZIP_ENTRIES=".azurefunctions/
.azurefunctions/function.deps.json
functions.metadata
receiver.dll
host.json"
  stub_script unzip <<'STUBEOF'
#!/usr/bin/env bash
printf 'unzip %s\n' "$*" >>"${STUB_LOG}"
printf '%s\n' "$ZIP_ENTRIES"
STUBEOF

  # The package setting the app reports. `PACKAGE_AFTER`, when set, is what the SECOND read
  # returns — which is how "the CLI lied and the deploy landed" is expressed.
  export PACKAGE_BEFORE='https://store.blob.core.windows.net/pkgs/old.zip'
  export AZ_BIN="${STUB_BIN}/az"
  stub_script az <<'STUBEOF'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *"appsettings list"*)
    if [ -f "${WORK}/deployed" ] && [ -n "${PACKAGE_AFTER:-}" ]; then
      printf '%s\n' "$PACKAGE_AFTER"
    else
      printf '%s\n' "$PACKAGE_BEFORE"
    fi
    ;;
  *"config-zip"*)
    touch "${WORK}/deployed"
    printf '%s\n' "${AZ_DEPLOY_OUTPUT:-Deployment successful.}"
    exit "${AZ_DEPLOY_EXIT:-0}"
    ;;
  *"deployment slot list"*) printf '%s\n' "${SLOT_HOST:-ghreceiver-stage.azurewebsites.net}" ;;
  *"functionapp show"*)     printf '%s\n' "${APP_HOST-ghreceiver.azurewebsites.net}" ;;
esac
exit 0
STUBEOF

  # One HTTP status per call, from a queue. An empty queue keeps returning the last value, so
  # a test only has to describe the interesting prefix.
  printf '200\n' >"${WORK}/statuses"
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
status="$(head -1 "${WORK}/statuses")"
if [ "$(wc -l <"${WORK}/statuses")" -gt 1 ]; then
  sed -i.bak '1d' "${WORK}/statuses" && rm -f "${WORK}/statuses.bak"
fi
printf '%s' "$status"
STUBEOF
}

queue_statuses() { printf '%s\n' "$@" >"${WORK}/statuses"; }

# ── the package shape ────────────────────────────────────────────────────────────────────

@test "a package nested one directory down is refused, and the message says which mistake it is" {
  # `zip -r package.zip publish` — the archive lists publish/functions.metadata. A substring
  # match would pass this, which is why the check is on the entry name at the root.
  ZIP_ENTRIES="publish/
publish/.azurefunctions/
publish/functions.metadata
publish/receiver.dll" run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing functions.metadata, .azurefunctions/ at the archive root"* ]]
  [[ "$output" == *"below the root"* ]]
  # It must not have reached the CLI at all.
  refute grep -q "config-zip" "$STUB_LOG"
}

@test "a package built by a glob, so without the dotfile directory, is refused" {
  # `zip -r ../package.zip *` — everything is at the root, and `.azurefunctions/` is gone.
  ZIP_ENTRIES="functions.metadata
receiver.dll
host.json" run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *".azurefunctions/"* ]]
  [[ "$output" != *"below the root"* ]]
  refute grep -q "config-zip" "$STUB_LOG"
}

@test "a runner with no unzip warns and deploys anyway, rather than refusing over a missing tool" {
  UNZIP_BIN=definitely-not-installed run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"was not checked"* ]]
  grep -q "config-zip" "$STUB_LOG"
}

# ── the exit code that lies ──────────────────────────────────────────────────────────────

@test "az exiting non-zero over a deploy that LANDED is not a failure" {
  # The whole reason this target does not trust the exit code. The CLI reports a poll of its
  # own status endpoint, not the outcome; WEBSITE_RUN_FROM_PACKAGE moving is the outcome.
  AZ_DEPLOY_EXIT=1 \
  AZ_DEPLOY_OUTPUT="ERROR: Operation returned an invalid status 'Bad Request'" \
  PACKAGE_AFTER='https://store.blob.core.windows.net/pkgs/new.zip' \
    run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"the deploy landed"* ]]
  [ "$(output_value deployed)" = "true" ]
}

@test "az exiting non-zero with the package UNMOVED is a failure" {
  # The other direction, and the one an unconditional `|| true` would swallow: a real refusal
  # reported as a successful deploy.
  AZ_DEPLOY_EXIT=1 \
  AZ_DEPLOY_OUTPUT="ERROR: Operation returned an invalid status 'Bad Request'" \
    run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not move"* ]]
  [ "$(output_value deployed)" = "false" ]
}

# ── the readiness poll, which is the only evidence ───────────────────────────────────────

@test "a first deploy that 503s and then answers passes" {
  # A freshly created Consumption app 503s from the site AND its SCM endpoint until content
  # is first published. Failing on the first 503 makes every first deploy red.
  queue_statuses 503 503 404
  run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "true" ]
  [ "$(output_value url)" = "https://ghreceiver.azurewebsites.net" ]
}

@test "404 at the root counts as an answer" {
  # The NORMAL result for a Function App whose only trigger is at /api/<name>. Demanding a
  # 200 here would fail every correctly deployed receiver.
  queue_statuses 404
  run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "true" ]
}

@test "an app that never answers fails, and the message names the runtime that causes it" {
  queue_statuses 503
  run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never answered"* ]]
  [[ "$output" == *"DOTNET-ISOLATED|10.0"* ]]
  [ "$(output_value deployed)" = "false" ]
}

@test "curl getting no answer at all is not mistaken for an answer" {
  queue_statuses 000
  run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never answered"* ]]
}

@test "a hostname the platform will not report is a failure, not a silent success" {
  # Without this the script would poll `https://` and report whatever that did.
  APP_HOST= queue_statuses 200
  APP_HOST= run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the default hostname"* ]]
  [[ "$output" == *"cannot prove it"* ]]
}

# ── modes ────────────────────────────────────────────────────────────────────────────────

@test "a preview with no slot validates the package and publishes NOTHING" {
  # Consumption has no deployment slots, so there is no destination that does not take
  # production traffic. Publishing anyway is how a branch reaches production.
  MODE=preview run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "false" ]
  refute grep -q "config-zip" "$STUB_LOG"
  [[ "$output" == *"no deployment slots"* ]]
}

@test "a preview WITH a slot publishes to the slot and verifies the slot's own hostname" {
  MODE=preview SLOT=stage run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--slot stage" "$STUB_LOG"
  grep -q "deployment slot list" "$STUB_LOG"
  [ "$(output_value url)" = "https://ghreceiver-stage.azurewebsites.net" ]
}

@test "a deploy with no slot passes no --slot at all" {
  run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  refute grep -q -- "--slot" "$STUB_LOG"
  grep -q -- "--resource-group rg-webhooks --name ghreceiver --src ${ARTIFACT_PATH}" "$STUB_LOG"
}

@test "a dry run publishes nothing and asks the platform nothing" {
  DRY_RUN=true run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value deployed)" = "false" ]
  refute grep -q "config-zip" "$STUB_LOG"
  refute grep -q "curl" "$STUB_LOG"
}

@test "an unsupported mode is refused by name" {
  MODE=teleport run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported mode 'teleport'"* ]]
}

# ── the required inputs ──────────────────────────────────────────────────────────────────

@test "a missing app name is refused before anything is called" {
  APP_NAME= run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"APP_NAME is required"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "an artifact that is not a file is refused" {
  ARTIFACT_PATH="${WORK}/nope.zip" run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a file"* ]]
}

@test "an empty artifact is refused" {
  : >"${WORK}/empty.zip"
  ARTIFACT_PATH="${WORK}/empty.zip" run bash "${SCRIPTS}/deploy-azure-functions-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is empty"* ]]
}
