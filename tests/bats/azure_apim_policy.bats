#!/usr/bin/env bats
#
# The two that must never regress:
#
#   * API Management compiles a policy only when it is published, so a set of documents can be
#     refused halfway. Every scope published before the refusal is put back, or cleared where it
#     had no policy, so the API never runs half the old set and half the new.
#   * A document naming an operation the API does not have is refused before ANYTHING is
#     published. This target publishes into infrastructure; it does not invent it.

load helper

setup() {
  setup_common
  cd "$WORK"
  export RUNNER_TEMP="${WORK}/runner-temp"
  mkdir -p "$RUNNER_TEMP"

  export SERVICE_NAME=webhooks
  export RESOURCE_GROUP=rg-webhooks
  export API_ID=github
  export ARTIFACT_PATH="${WORK}/policies"
  mkdir -p "$ARTIFACT_PATH"
  printf '<policies><inbound><base /></inbound></policies>\n' >"${ARTIFACT_PATH}/api.xml"
  printf '<policies><inbound><return-response /></inbound></policies>\n' >"${ARTIFACT_PATH}/webhook.xml"

  # What the fake instance has. OPERATIONS: the operation ids that exist. EXISTING: the scopes
  # that already carry a policy. REFUSE: the scope whose PUT is rejected.
  export OPERATIONS="webhook ping"
  export EXISTING="api webhook"
  export REFUSE=""
  export API_PATH=github
  export AZ_BIN="${STUB_BIN}/az"
  stub_script az <<'STUBEOF'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >>"${STUB_LOG}"
method="" url="" body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --body) body="${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  "") [ -n "${NO_SUBSCRIPTION:-}" ] && exit 1; printf 'sub-1234\n'; exit 0 ;;
esac
path="${url%%\?*}"
scope=""
case "$path" in
  */operations/*/policies/policy) scope="${path%/policies/policy}"; scope="${scope##*/}" ;;
  */policies/policy) scope=api ;;
esac
if [ -n "$scope" ]; then
  case "$method" in
    get)
      [ -n "${READ_FAIL:-}" ] && { printf 'Forbidden({"error":{"code":"AuthorizationFailed"}})\n' >&2; exit 1; }
      case " ${EXISTING} " in
        *" ${scope} "*) printf '{"properties":{"format":"rawxml","value":"<policies>old %s</policies>"}}\n' "$scope"; exit 0 ;;
      esac
      printf 'Not Found({"error":{"code":"ResourceNotFound"}})\n' >&2
      exit 1
      ;;
    put)
      if [ "$scope" = "${REFUSE}" ]; then
        printf "Bad Request({\"error\":{\"code\":\"ValidationError\",\"message\":\"Error in element 'set-variable'\"}})\n" >&2
        exit 1
      fi
      n="$(ls "${WORK}" | grep -c '^put-' || true)"
      cp "$body" "${WORK}/put-${n}-${scope}.json"
      exit 0
      ;;
    delete) exit 0 ;;
  esac
fi
case "$path" in
  */operations/*)
    op="${path##*/}"
    case " ${OPERATIONS} " in *" ${op} "*) exit 0 ;; esac
    exit 1
    ;;
  */apis/*)
    [ -n "${API_MISSING:-}" ] && exit 1
    printf '%s\n' "$API_PATH"
    exit 0
    ;;
  */service/*) printf 'https://webhooks.azure-api.net\n'; exit 0 ;;
esac
exit 0
STUBEOF
}

puts() { grep -c -- '--method put' "$STUB_LOG" || true; }

# ── publishing ────────────────────────────────────────────────────────────────────────────

@test "every document is published to its scope, as rawxml, and the outputs say where" {
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--method put --url /subscriptions/sub-1234/resourceGroups/rg-webhooks/providers/Microsoft.ApiManagement/service/webhooks/apis/github/policies/policy?api-version=" "$STUB_LOG"
  grep -q -- "--method put --url /subscriptions/sub-1234/resourceGroups/rg-webhooks/providers/Microsoft.ApiManagement/service/webhooks/apis/github/operations/webhook/policies/policy?api-version=" "$STUB_LOG"
  [ "$(jq -r .properties.format "${WORK}"/put-*-webhook.json)" = "rawxml" ]
  [[ "$(jq -r .properties.value "${WORK}"/put-*-webhook.json)" == *"<return-response />"* ]]
  [ "$(output_value deployed)" = "true" ]
  [ "$(output_value url)" = "https://webhooks.azure-api.net/github" ]
  [[ "$(output_value version-id)" =~ ^[0-9a-f]{64}$ ]]
}

@test "the If-Match header is sent, so an existing policy is replaced rather than refused" {
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -- '--method put' "$STUB_LOG" | grep -c 'If-Match=\*')" -eq 2 ]
}

@test "apim-policy-format xml is passed through as the document's format" {
  POLICY_FORMAT=xml run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .properties.format "${WORK}"/put-*-api.json)" = "xml" ]
}

@test "an API at the gateway root reports the gateway URL alone" {
  API_PATH="" run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value url)" = "https://webhooks.azure-api.net" ]
}

@test "the version id follows the documents, not the run" {
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  first="$(output_value version-id)"
  : >"$GITHUB_OUTPUT"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$(output_value version-id)" = "$first" ]
  printf '<policies><inbound /></policies>\n' >"${ARTIFACT_PATH}/webhook.xml"
  : >"$GITHUB_OUTPUT"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$(output_value version-id)" != "$first" ]
}

# ── all or nothing ────────────────────────────────────────────────────────────────────────

@test "a refused document puts back the scopes published before it, and says which it was" {
  printf '<policies><inbound /></policies>\n' >"${ARTIFACT_PATH}/ping.xml"
  # Sorted order is api, ping, webhook: api and ping publish, webhook is refused.
  EXISTING="api webhook" REFUSE=webhook run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused ${ARTIFACT_PATH}/webhook.xml"* ]]
  [[ "$output" == *"Error in element 'set-variable'"* ]]
  # api had a policy: it is PUT back with the old value.
  grep -q -- '"old api"\|old api' "${WORK}"/put-*-api.json
  [[ "$output" == *"put the previous policy back on 'api'"* ]]
  # ping had none: it is cleared.
  grep -q -- "--method delete --url .*/operations/ping/policies/policy" "$STUB_LOG"
  [[ "$output" == *"cleared 'ping'"* ]]
  [ "$(output_value deployed)" = "false" ]
}

@test "a refused FIRST document leaves nothing to put back" {
  REFUSE=api run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [ "$(puts)" -eq 1 ]
  refute grep -q -- "--method delete" "$STUB_LOG"
}

@test "a current policy that cannot be read stops the run before anything is published" {
  READ_FAIL=1 run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be put back"* ]]
  [ "$(puts)" -eq 0 ]
}

# ── what it will not create ──────────────────────────────────────────────────────────────

@test "a document naming an operation the API does not have is refused before any publish" {
  printf '<policies><inbound /></policies>\n' >"${ARTIFACT_PATH}/nope.xml"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no operation(s) nope"* ]]
  [ "$(puts)" -eq 0 ]
}

@test "an API that does not exist is refused, and the message says to create it first" {
  API_MISSING=1 run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not found"* ]]
  [[ "$output" == *"create the API and its operations"* ]]
  [ "$(puts)" -eq 0 ]
}

@test "no selected subscription is a failure that names the credential inputs" {
  NO_SUBSCRIPTION=1 run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"azure-client-id"* ]]
}

# ── preview and dry run ──────────────────────────────────────────────────────────────────

@test "a preview checks the documents and publishes NOTHING, asking Azure nothing" {
  MODE=preview run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT published"* ]]
  [ ! -s "$STUB_LOG" ]
  [ "$(output_value deployed)" = "false" ]
  [[ "$(output_value version-id)" =~ ^[0-9a-f]{64}$ ]]
}

@test "a dry run publishes nothing and asks Azure nothing" {
  DRY_RUN=true run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN: would publish"* ]]
  [ ! -s "$STUB_LOG" ]
}

# ── the documents themselves ─────────────────────────────────────────────────────────────

@test "an artifact that is not a directory is refused" {
  ARTIFACT_PATH="${ARTIFACT_PATH}/api.xml" run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a directory"* ]]
}

@test "a directory with no documents is refused" {
  rm -f "${ARTIFACT_PATH}"/*.xml
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds no *.xml policy documents"* ]]
}

@test "a file that is not a policy document is refused" {
  printf '<configuration />\n' >"${ARTIFACT_PATH}/webhook.xml"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a policy document"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "an empty document is refused" {
  : >"${ARTIFACT_PATH}/webhook.xml"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is empty"* ]]
}

@test "a file name that cannot be an operation id is refused" {
  printf '<policies />\n' >"${ARTIFACT_PATH}/-bad.xml"
  run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name an operation"* ]]
}

@test "an unsupported policy format is refused by name" {
  POLICY_FORMAT=json run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apim-policy-format 'json'"* ]]
}

@test "an unsupported mode is refused by name" {
  MODE=destroy run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported mode 'destroy'"* ]]
}

@test "a missing instance name is refused before anything is called" {
  SERVICE_NAME="" run bash "${SCRIPTS}/deploy-azure-apim-policy.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apim-service-name"* ]]
  [ ! -s "$STUB_LOG" ]
}
