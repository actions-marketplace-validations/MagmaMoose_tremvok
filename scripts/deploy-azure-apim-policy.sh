#!/usr/bin/env bash
# The API Management target: publish policy documents into an API that already exists, and put
# the previous ones back if API Management refuses any of them.
#
# WHAT IT PUBLISHES, AND WHAT IT DOES NOT CREATE
#
# `artifact-path` is a directory of policy documents: `api.xml` for the API scope and
# `<operation-id>.xml` for each operation. Nothing else in it is read. The instance, the API and
# its operations are infrastructure, created by whatever creates infrastructure; this target
# publishes behaviour into them, the way `azure-functions-zip` publishes code into a Function App
# that already exists. A document naming an operation the API does not have is refused before
# anything is published, rather than creating an operation nobody declared.
#
# WHY `az rest` AND NOT A NARROWER COMMAND
#
# The CLI has no `az apim ... policy` command group, so the ARM call is made directly. The URL is
# a resource id without a host, which `az rest` prefixes with the current cloud's Resource
# Manager endpoint, so a sovereign cloud works without an input for it.
#
# ALL OR NOTHING
#
# API Management checks a policy only when it is published: the XML and every C# expression in it
# are compiled on the PUT, and there is no dry run. So a set of documents can fail halfway, and an
# API left half on the old policies and half on the new is the one outcome worse than either.
# Before publishing, the current document at every scope is read and kept. If any PUT is refused,
# the scopes already published are put back (or cleared, where there was no policy before), and
# the run fails naming the document and quoting API Management's reason.
#
# WHAT PROVES IT WENT LIVE
#
# A document API Management accepted is compiled and in force on the gateway within seconds.
# What it DOES is the caller's to assert: `verify-url` with `verify-method` and `verify-status`,
# for instance an unsigned POST to a webhook route answering 401.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SERVICE_NAME="${SERVICE_NAME:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
API_ID="${API_ID:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-}"
POLICY_FORMAT="${POLICY_FORMAT:-rawxml}"
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
# The API Management REST version the calls are made against. Overridable, not an input.
API_VERSION="${API_VERSION:-2024-05-01}"
# Overridable so bats can put a recorder in front of it.
AZ_BIN="${AZ_BIN:-az}"

tremvok::require SERVICE_NAME "apim-service-name"
tremvok::require RESOURCE_GROUP "apim-resource-group"
tremvok::require API_ID "apim-api-id"
tremvok::require ARTIFACT_PATH "the directory of policy documents"

case "$POLICY_FORMAT" in
  rawxml | xml) ;;
  *) tremvok::fail "apim-policy-format '${POLICY_FORMAT}' is not one of rawxml, xml" ;;
esac

case "$MODE" in
  deploy | rollback | preview) ;;
  *) tremvok::fail "unsupported mode '${MODE}' for target azure-apim-policy (expected deploy, preview or rollback)" ;;
esac

[[ -d "$ARTIFACT_PATH" ]] \
  || tremvok::fail "artifact-path '${ARTIFACT_PATH}' is not a directory. azure-apim-policy publishes a directory of policy documents: api.xml for the API scope and <operation-id>.xml for each operation."

# ── the documents ─────────────────────────────────────────────────────────────────────────
docs=()
scopes=()
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
while IFS= read -r file; do
  name="$(basename "$file" .xml)"
  [[ "$name" =~ $name_re ]] \
    || tremvok::fail "'${file}' does not name an operation: an operation id is letters, digits, '.', '_' and '-'"
  [[ -s "$file" ]] || tremvok::fail "'${file}' is empty"
  # Not a parse. A rawxml document is deliberately not well-formed XML (its C# expressions are
  # unescaped), and API Management is the only parser that counts. This catches the wrong file
  # in the directory, which is what a local check can catch.
  if ! grep -q '<policies' "$file" || ! grep -q '</policies>' "$file"; then
    tremvok::fail "'${file}' is not a policy document: it has no <policies> element"
  fi
  docs+=("$file")
  scopes+=("$name")
done < <(find "$ARTIFACT_PATH" -maxdepth 1 -type f -name '*.xml' | LC_ALL=C sort)

(( ${#docs[@]} > 0 )) \
  || tremvok::fail "artifact-path '${ARTIFACT_PATH}' holds no *.xml policy documents. Name them api.xml for the API scope and <operation-id>.xml for each operation."

# One digest over every document and the scope it is published to, so a run can be tied to the
# policy set it published. API Management keeps no content hash of its own to compare it with.
version_id="$(
  for i in "${!docs[@]}"; do
    printf '%s\n' "${scopes[$i]}"
    cat "${docs[$i]}"
  done | openssl dgst -sha256 -hex | awk '{print $NF}'
)"
tremvok::log "${#docs[@]} policy document(s) for ${SERVICE_NAME}/${API_ID}, sha256=${version_id}"

# ── where does this mode publish? ─────────────────────────────────────────────────────────
#
# A pull request must not publish onto the routes production serves. For a policy the only such
# destination would be an API revision, which is its own lifecycle and not this target's to
# invent. So a preview checks the documents and publishes nothing, and says so.
if [[ "$MODE" == "preview" ]]; then
  tremvok::notice "mode=preview: ${#docs[@]} policy document(s) were checked and NOT published. A policy has no destination that takes no production traffic short of an API revision, which this target does not create."
  tremvok::summary "## API Management — preview, not published"
  tremvok::summary ""
  tremvok::summary "${#docs[@]} policy document(s) were checked and not published: \`mode: preview\` has no destination on this API."
  tremvok::set_output deployed "false"
  tremvok::set_output url ""
  tremvok::set_output version-id "$version_id"
  exit 0
fi

if tremvok::is_true "$DRY_RUN"; then
  for i in "${!docs[@]}"; do
    tremvok::log "DRY RUN: would publish ${docs[$i]} to $([[ "${scopes[$i]}" == api ]] && printf 'the API scope' || printf 'operation %s' "${scopes[$i]}")"
  done
  tremvok::set_output deployed "false"
  tremvok::set_output url ""
  tremvok::set_output version-id "$version_id"
  exit 0
fi

# ── the API, and every operation a document names, must exist ─────────────────────────────
subscription="$("$AZ_BIN" account show --query id --output tsv 2>/dev/null || true)"
[[ -n "$subscription" ]] \
  || tremvok::fail "no Azure subscription is selected, so there is no API Management instance to publish to. Set azure-client-id, azure-tenant-id and azure-subscription-id, or sign in during an earlier step."

service="/subscriptions/${subscription}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${SERVICE_NAME}"
api="${service}/apis/${API_ID}"

api_path="$("$AZ_BIN" rest --method get --url "${api}?api-version=${API_VERSION}" \
  --query properties.path --output tsv 2>/dev/null)" \
  || tremvok::fail "API '${API_ID}' was not found on API Management '${SERVICE_NAME}' in '${RESOURCE_GROUP}'. This target publishes policies into an API that already exists; create the API and its operations with your infrastructure first."

missing=""
for i in "${!docs[@]}"; do
  [[ "${scopes[$i]}" == api ]] && continue
  if ! "$AZ_BIN" rest --method get --url "${api}/operations/${scopes[$i]}?api-version=${API_VERSION}" --output none 2>/dev/null; then
    missing="${missing:+${missing}, }${scopes[$i]}"
  fi
done
[[ -z "$missing" ]] \
  || tremvok::fail "API '${API_ID}' has no operation(s) ${missing}. A document is named after the operation it is published to; nothing was published."

scope_url() {
  if [[ "$1" == api ]]; then
    printf '%s/policies/policy' "$api"
  else
    printf '%s/operations/%s/policies/policy' "$api" "$1"
  fi
}

# ── keep what is there now ────────────────────────────────────────────────────────────────
# Read as rawxml whatever this run publishes in, because it is only ever put back as-is. A scope
# with no policy answers 404, which is recorded as "clear it" rather than treated as an error;
# any other failure stops the run, since a document that cannot be put back cannot be replaced.
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/tremvok-apim.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for i in "${!docs[@]}"; do
  err="${work}/read-${i}.err"
  if "$AZ_BIN" rest --method get --url "$(scope_url "${scopes[$i]}")?api-version=${API_VERSION}&format=rawxml" \
      --output json >"${work}/before-${i}.json" 2>"$err"; then
    continue
  fi
  if grep -qiE 'not ?found|404' "$err"; then
    rm -f "${work}/before-${i}.json"
    continue
  fi
  cat "$err" >&2
  tremvok::fail "could not read the current policy for '${scopes[$i]}', so it could not be put back if the publish failed. Nothing was published."
done

restore() {
  local j scope
  for (( j = ${#published[@]} - 1; j >= 0; j-- )); do
    scope="${scopes[${published[$j]}]}"
    if [[ -f "${work}/before-${published[$j]}.json" ]]; then
      jq '{properties: {format: "rawxml", value: .properties.value}}' \
        "${work}/before-${published[$j]}.json" >"${work}/restore.json"
      if "$AZ_BIN" rest --method put --url "$(scope_url "$scope")?api-version=${API_VERSION}" \
          --headers "Content-Type=application/json" "If-Match=*" \
          --body "@${work}/restore.json" --output none; then
        tremvok::warn "put the previous policy back on '${scope}'"
      else
        tremvok::warn "could NOT put the previous policy back on '${scope}'; it is running the new document"
      fi
    else
      if "$AZ_BIN" rest --method delete --url "$(scope_url "$scope")?api-version=${API_VERSION}" \
          --headers "If-Match=*" --output none; then
        tremvok::warn "cleared '${scope}', which had no policy before this run"
      else
        tremvok::warn "could NOT clear '${scope}'; it is running the new document"
      fi
    fi
  done
}

# ── publish ───────────────────────────────────────────────────────────────────────────────
published=()
for i in "${!docs[@]}"; do
  jq -n --arg format "$POLICY_FORMAT" --rawfile value "${docs[$i]}" \
    '{properties: {format: $format, value: $value}}' >"${work}/body.json"
  err="${work}/put-${i}.err"
  if "$AZ_BIN" rest --method put --url "$(scope_url "${scopes[$i]}")?api-version=${API_VERSION}" \
      --headers "Content-Type=application/json" "If-Match=*" \
      --body "@${work}/body.json" --output none 2>"$err"; then
    published+=("$i")
    tremvok::log "published ${docs[$i]} to '${scopes[$i]}'"
    continue
  fi
  cat "$err" >&2
  if (( ${#published[@]} > 0 )); then
    restore
  fi
  tremvok::set_output deployed "false"
  tremvok::fail "API Management refused ${docs[$i]} for '${scopes[$i]}' (its reason is above: it compiles every expression on publish). $(( ${#published[@]} )) document(s) published before it were put back, so the API is on the policies it had before this run."
done

# ── where does it answer? ─────────────────────────────────────────────────────────────────
gateway="$("$AZ_BIN" rest --method get --url "${service}?api-version=${API_VERSION}" \
  --query properties.gatewayUrl --output tsv 2>/dev/null || true)"
url=""
if [[ -n "$gateway" && "$gateway" != "None" ]]; then
  url="${gateway%/}${api_path:+/${api_path}}"
fi

tremvok::set_output deployed "true"
tremvok::set_output url "$url"
tremvok::set_output version-id "$version_id"

tremvok::summary "## API Management — ${MODE}"
tremvok::summary ""
tremvok::summary "| Scope | Document |"
tremvok::summary "|:--|:--|"
for i in "${!docs[@]}"; do
  tremvok::summary "| \`${scopes[$i]}\` | \`${docs[$i]}\` |"
done
tremvok::summary ""
tremvok::summary "API \`${API_ID}\` on \`${SERVICE_NAME}\`${url:+, ${url}}. Policy set sha256 \`${version_id}\`."
tremvok::log "published ${#docs[@]} policy document(s) to ${SERVICE_NAME}/${API_ID}"
