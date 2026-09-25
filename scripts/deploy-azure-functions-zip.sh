#!/usr/bin/env bash
# The Azure Functions target: publish a zip to a Function App and prove the app serves it.
#
# WHY `az functionapp deployment source config-zip` AND NOT THE OTHER TWO.
#
# Three mechanisms can put a zip on a Function App:
#
#   1. `az functionapp deployment source config-zip`  — one command. It uploads the package
#      to the storage account the app already has, sets WEBSITE_RUN_FROM_PACKAGE to the blob,
#      and restarts the app. Chosen.
#   2. The Kudu `/api/zipdeploy` endpoint directly — the same thing one layer down, but the
#      caller now owns the SCM credential, the polling of `/api/deployments/latest`, and the
#      difference between a 202 and a finished deploy. That is three more things to get wrong
#      for no capability this target needs.
#   3. Setting WEBSITE_RUN_FROM_PACKAGE to a blob URL by hand — the most control and the most
#      moving parts: a storage account, a container, a SAS or a managed identity, and a
#      lifecycle for packages nothing now cleans up. It is the right answer when the package
#      must live somewhere specific for audit or immutability reasons, and it is not the right
#      default.
#
# (1) is chosen because the app already has the storage account it needs, and because the two
# alternatives buy control this target does not use. The cost is the bug below.
#
# THE EXIT CODE IS NOT EVIDENCE. `config-zip` has been observed printing
#
#     ERROR: Operation returned an invalid status 'Bad Request'
#
# and exiting non-zero while the deploy SUCCEEDED: WEBSITE_RUN_FROM_PACKAGE pointed at the
# newly uploaded blob and the app served the new code. The CLI is reporting a poll of its own
# status endpoint, not the outcome. Treating that exit code as fatal fails a green deploy;
# treating it as success ignores real failures. So this script does neither: a non-zero exit
# is corroborated against the platform — did WEBSITE_RUN_FROM_PACKAGE actually move? — and
# then, either way, the app has to answer. Which is the whole promise: ship it, prove it went
# live.
#
# PLATFORM STATE IS NOT EVIDENCE EITHER. `azurerm_linux_function_app` reports
# `state: Running` and `availabilityState: Normal` while the site returns 503 with no log
# output at all. Nothing short of an HTTP response from the app proves anything, so the
# readiness poll below is not optional and not skippable.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

APP_NAME="${APP_NAME:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
SLOT="${SLOT:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-}"
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
READY_ATTEMPTS="${READY_ATTEMPTS:-30}"
READY_DELAY="${READY_DELAY:-10}"
# Overridable so bats can put a recorder in front of them.
AZ_BIN="${AZ_BIN:-az}"

tremvok::require APP_NAME "functions-app-name"
tremvok::require RESOURCE_GROUP "functions-resource-group"
tremvok::require ARTIFACT_PATH "the built .zip"

[[ -f "$ARTIFACT_PATH" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is not a file"
[[ -s "$ARTIFACT_PATH" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is empty"

# ── the package has to be shaped like a Functions package ────────────────────────────────
#
# The silent failure this guards. A zip of the publish directory ITSELF (`publish/` as a
# folder inside the archive), or one built with a glob that skipped dotfiles, deploys
# perfectly cleanly and then serves nothing: no error, no log line, just 404 on every route.
# The worker discovers functions from `functions.metadata` and loads the host extensions from
# the dotfile directory `.azurefunctions/`, and both must be at the ARCHIVE ROOT.
# `zip -r ../x.zip *` omits dotfiles; `zip -r x.zip publish` nests everything one level down.
# Both look right in a listing and neither works.
#
# Checked at the root specifically, which is why this reads entry NAMES rather than grepping
# the archive's bytes: a nested package contains the literal text `publish/functions.metadata`,
# so a substring match would pass the very mistake this exists to catch.
#
# `unzip` is not on every runner — the org's self-hosted pool images are minimal — so its
# absence WARNS rather than failing. A check that cannot run is not evidence of a bad package,
# and refusing a deploy because a listing tool is missing would be its own outage.
UNZIP_BIN="${UNZIP_BIN:-unzip}"

if ! command -v "$UNZIP_BIN" >/dev/null 2>&1; then
  tremvok::warn "no '${UNZIP_BIN}' on this runner, so the package layout was not checked. A zip whose contents are nested under a directory, or built by a glob that skipped dotfiles, deploys cleanly and then serves nothing on every route."
else
  entries="$("$UNZIP_BIN" -Z1 "$ARTIFACT_PATH" 2>/dev/null || true)"
  [[ -n "$entries" ]] || tremvok::fail "artifact-path '${ARTIFACT_PATH}' could not be read as a zip archive"

  missing=""
  # An exact line: `functions.metadata` at the root, not `publish/functions.metadata`.
  grep -qx 'functions\.metadata' <<<"$entries" || missing="functions.metadata"
  # A root-level directory: every entry under it starts with the name and nothing precedes it.
  if ! grep -q '^\.azurefunctions/' <<<"$entries"; then
    missing="${missing:+${missing}, }.azurefunctions/"
  fi

  if [[ -n "$missing" ]]; then
    nested=""
    # A LEADING slash is the whole point: a root-level `functions.metadata` also matches
    # `(^|/)functions\.metadata$`, so the unanchored form printed the nesting hint for the
    # glob mistake, which is a different mistake with a different fix.
    if grep -q '/functions\.metadata$' <<<"$entries"; then
      nested=" The archive does contain functions.metadata, but below the root, which is the 'zip -r package.zip <publish-dir>' mistake."
    fi
    tremvok::fail "artifact-path '${ARTIFACT_PATH}' is missing ${missing} at the archive root.${nested} That package deploys cleanly and then serves nothing: the worker finds no functions and every route 404s. Zip the CONTENTS of the publish directory, dotfiles included: 'cd <publish-dir> && zip -r -q ../package.zip .' — not 'zip -r package.zip <publish-dir>', and not a glob, which skips dotfiles."
  fi

  tremvok::log "package ${ARTIFACT_PATH} carries functions.metadata and .azurefunctions/ at the root"
fi

# ── where does this mode publish? ────────────────────────────────────────────────────────
#
# A pull request must not publish onto the routes production serves, which is the same rule
# the Cloudflare target enforces with `versions upload`. Azure's equivalent of a preview
# destination is a deployment slot — and Linux Consumption, which is the plan this target was
# measured on, DOES NOT SUPPORT SLOTS. So there is genuinely nowhere to put a preview, and the
# honest thing is to say so and stop rather than quietly publishing a branch to production.
# Set `functions-slot` on a plan that has slots (Premium, Dedicated) and a preview goes there.
slot_args=()
if [[ -n "$SLOT" ]]; then
  slot_args=( --slot "$SLOT" )
fi

if [[ "$MODE" == "preview" && -z "$SLOT" ]]; then
  tremvok::notice "mode=preview with no functions-slot: the package was validated and NOT published. A Consumption plan has no deployment slots, so there is no destination that does not take production traffic. Set functions-slot on a Premium or Dedicated plan to publish previews to a slot."
  tremvok::summary "## Azure Functions — preview, not published"
  tremvok::summary ""
  tremvok::summary "The package was validated and not published: \`mode: preview\` has no destination on this app."
  tremvok::summary "A Consumption plan has no deployment slots. Set \`functions-slot\` on a Premium or Dedicated plan to publish previews to a slot."
  tremvok::set_output deployed "false"
  tremvok::set_output url ""
  tremvok::set_output version-id ""
  exit 0
fi

case "$MODE" in
  deploy | rollback | preview) ;;
  *) tremvok::fail "unsupported mode '${MODE}' for target azure-functions-zip (expected deploy, preview or rollback)" ;;
esac

target_label="${APP_NAME}${SLOT:+ (slot ${SLOT})}"

# The digest is reported so a run can be tied to the bytes it published. Azure exposes no
# per-deploy content hash to compare it against — unlike Lambda's CodeSha256 — so this is a
# record, not a check, and the app answering is what this target verifies instead.
artifact_sha256="$(openssl dgst -sha256 -hex "$ARTIFACT_PATH" | awk '{print $NF}')"
tremvok::log "artifact ${ARTIFACT_PATH} sha256=${artifact_sha256}"

if tremvok::is_true "$DRY_RUN"; then
  tremvok::log "DRY RUN: ${AZ_BIN} functionapp deployment source config-zip --resource-group ${RESOURCE_GROUP} --name ${APP_NAME} ${slot_args[*]-} --src ${ARTIFACT_PATH}"
  tremvok::set_output deployed "false"
  tremvok::set_output url ""
  tremvok::set_output version-id "$artifact_sha256"
  exit 0
fi

# ── what is the app running now? ─────────────────────────────────────────────────────────
# Read BEFORE the deploy, so a non-zero exit can be judged on whether the package actually
# moved rather than merely on whether the setting is non-empty.
package_setting() {
  "$AZ_BIN" functionapp config appsettings list \
    --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" ${slot_args[@]+"${slot_args[@]}"} \
    --query "[?name=='WEBSITE_RUN_FROM_PACKAGE'].value | [0]" --output tsv 2>/dev/null || true
}

package_before="$(package_setting)"

# ── publish ──────────────────────────────────────────────────────────────────────────────
log_file="${RUNNER_TEMP:-/tmp}/tremvok-az-config-zip.log"
code=0
# `pipefail` is set, so `| tee` reports az's status and not tee's — the exact trap this
# repository exists to stop repeating.
"$AZ_BIN" functionapp deployment source config-zip \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_NAME" \
  ${slot_args[@]+"${slot_args[@]}"} \
  --src "$ARTIFACT_PATH" 2>&1 | tee "$log_file" || code=$?

if (( code != 0 )); then
  # The known liar. Rather than matching the message — which will be reworded — ask the
  # platform the only question that settles it: is the app now pointed at a different
  # package than it was before this step ran?
  package_after="$(package_setting)"
  if [[ -n "$package_after" && "$package_after" != "$package_before" ]]; then
    tremvok::warn "az exited ${code} but the deploy landed: WEBSITE_RUN_FROM_PACKAGE moved to a new package. This CLI reports a poll of its own status endpoint, not the outcome, and has been seen printing \"Operation returned an invalid status 'Bad Request'\" over a successful deploy. Continuing to the readiness check, which is what actually decides."
  else
    tremvok::set_output deployed "false"
    tremvok::fail "az functionapp deployment source config-zip exited ${code} and WEBSITE_RUN_FROM_PACKAGE did not move, so the package was not published. The CLI output is above."
  fi
fi
rm -f "$log_file"

# ── where does it answer? ────────────────────────────────────────────────────────────────
# Asked of the platform rather than assembled from the app name. A slot's hostname is not
# reliably `<app>-<slot>.azurewebsites.net` any more: apps created with unique default
# hostnames carry a generated suffix, and a constructed host would poll a name that resolves
# to nothing and report the deploy as dead.
if [[ -n "$SLOT" ]]; then
  host="$("$AZ_BIN" functionapp deployment slot list \
    --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --query "[?name=='${SLOT}'].defaultHostName | [0]" --output tsv 2>/dev/null || true)"
else
  host="$("$AZ_BIN" functionapp show \
    --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" \
    --query defaultHostName --output tsv 2>/dev/null || true)"
fi

if [[ -z "$host" || "$host" == "None" ]]; then
  tremvok::set_output deployed "false"
  tremvok::fail "could not read the default hostname for ${target_label}, so there is nothing to verify against. The package may have been published; this run cannot prove it."
fi
url="https://${host}"

# ── the only evidence that counts ────────────────────────────────────────────────────────
#
# Any HTTP answer proves the host is up and serving this app. A 404 at the root is the
# NORMAL result for a Function App whose only trigger is at /api/<name>, so it passes: this
# checks that the app is alive, and `verify-url` is where a caller asserts what a particular
# route does.
#
# Two statuses do not pass. `000` is curl failing to get an answer at all — DNS, connect, TLS
# or timeout. `503` is the state this target exists to catch: a freshly created Consumption
# app returns it from both the site and its SCM endpoint until content is first published,
# and an app that never leaves it is a deploy that uploaded and never bound. Retrying through
# it is what makes a FIRST deploy work; never leaving it is a failure.
# shellcheck disable=SC2329  # invoked by name through tremvok::retry
answers() {
  local status
  status="$(curl --silent --show-error --location --max-time 15 \
    --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null || printf '000')"
  case "$status" in
    000)
      tremvok::log "  ${url} -> no answer (DNS, connect, TLS or timeout)"
      return 1
      ;;
    503)
      tremvok::log "  ${url} -> 503 (the app has not started serving yet)"
      return 1
      ;;
    *)
      tremvok::log "  ${url} -> ${status}"
      return 0
      ;;
  esac
}

tremvok::log "waiting for ${target_label} to answer on ${url}"
if ! tremvok::retry "$READY_ATTEMPTS" "$READY_DELAY" answers; then
  tremvok::set_output deployed "false"
  tremvok::fail "${target_label} never answered on ${url} after ${READY_ATTEMPTS} attempts. The package was published and the app is not serving it. Platform state is no help here: a Function App in this condition reports state Running and availabilityState Normal while returning 503 with no log output. Check the worker runtime version — a Linux Consumption app on DOTNET-ISOLATED|10.0 never starts, and 9.0 is the version known to work."
fi

tremvok::set_output deployed "true"
tremvok::set_output url "$url"
tremvok::set_output version-id "$artifact_sha256"

tremvok::summary "## Azure Functions — ${MODE}"
tremvok::summary ""
tremvok::summary "| | |"
tremvok::summary "|:--|:--|"
tremvok::summary "| App | \`${APP_NAME}\` |"
if [[ -n "$SLOT" ]]; then
  tremvok::summary "| Slot | \`${SLOT}\` |"
fi
tremvok::summary "| URL | ${url} |"
tremvok::summary "| Package sha256 | \`${artifact_sha256}\` |"
tremvok::summary "| Answering | yes |"
tremvok::log "published to ${target_label} and it answers on ${url}"
