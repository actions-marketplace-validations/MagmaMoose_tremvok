#!/usr/bin/env bats
#
# The Google third of assume_role.bats and azure_login.bats, and the same three things matter:
# it must not leak the token, it must fail loudly when the workflow forgot `id-token: write`,
# and it must do nothing when no provider is configured — because "do nothing" is what keeps
# `google-github-actions/auth` in an earlier step a supported way to use this target.
#
# Plus one this one has on its own: the credential it writes is a FILE, and a token file that
# is world-readable on a shared self-hosted runner is the whole point of not using a key.

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=MagmaMoose/infra
  export GITHUB_RUN_ID=12345
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.test/?foo=bar'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  export WORKLOAD_IDENTITY_PROVIDER='projects/123456/locations/global/workloadIdentityPools/github/providers/tremvok'
  export CREDENTIAL_DIR="${WORK}/creds"
  mkdir -p "$CREDENTIAL_DIR"

  # One curl stub for three different calls: minting the OIDC token, the STS exchange, and
  # the impersonation. Each answers in its own shape so a test can break exactly one.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *sts.googleapis.com*)
    [ "${STS_FAILS:-false}" = "true" ] && { printf '{"error":"invalid_request","error_description":"the attribute condition did not match"}'; exit 0; }
    printf '{"access_token":"ya29.federated-s3cr3t","expires_in":3600}' ;;
  *generateAccessToken*)
    [ "${IMPERSONATION_FAILS:-false}" = "true" ] && { printf '{"error":{"message":"caller does not have permission"}}'; exit 0; }
    printf '{"accessToken":"ya29.impersonated-s3cr3t"}' ;;
  *)
    printf '{"value":"%s"}' "${OIDC_TOKEN-header.payload.s3cr3t-github-token}" ;;
esac
exit 0
STUBEOF
}

config_file() { printf '%s/tremvok-gcp-credentials.json' "$CREDENTIAL_DIR"; }
token_file() { printf '%s/tremvok-gcp-oidc-token' "$CREDENTIAL_DIR"; }

@test "no provider is a no-op, not a failure" {
  WORKLOAD_IDENTITY_PROVIDER= run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a provider without id-token: write fails with the fix in the message" {
  ACTIONS_ID_TOKEN_REQUEST_URL= run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

@test "a pool name instead of a provider resource name is refused before any call" {
  WORKLOAD_IDENTITY_PROVIDER='projects/123456/locations/global/workloadIdentityPools/github' \
    run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"full resource name"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "every token is masked before it is used" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  mask_line="$(grep -n '::add-mask::header.payload.s3cr3t-github-token' <<<"$output" | cut -d: -f1)"
  done_line="$(grep -n 'federated with' <<<"$output" | cut -d: -f1)"
  [ -n "$mask_line" ]
  [ "$mask_line" -lt "$done_line" ]
  [[ "$output" == *"::add-mask::ya29.federated-s3cr3t"* ]]
}

@test "the token file is 0600, and is created narrow rather than narrowed afterwards" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  mode="$(ls -l "$(token_file)" | cut -c1-10)"
  [ "$mode" = "-rw-------" ]
}

@test "the credential config is external_account pointing at the token file" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .type "$(config_file)")" = "external_account" ]
  [ "$(jq -r .audience "$(config_file)")" = "//iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}" ]
  [ "$(jq -r .credential_source.file "$(config_file)")" = "$(token_file)" ]
  [ "$(jq -r .credential_source.format.type "$(config_file)")" = "text" ]
}

@test "no service account means no impersonation url and no impersonation call" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.service_account_impersonation_url // "absent"' "$(config_file)")" = "absent" ]
  refute grep -q 'generateAccessToken' "$STUB_LOG"
}

@test "a service account adds the impersonation url and is proved before the run continues" {
  GCP_SERVICE_ACCOUNT=ci@proj.iam.gserviceaccount.com run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .service_account_impersonation_url "$(config_file)")" == *"ci@proj.iam.gserviceaccount.com:generateAccessToken" ]]
  grep -q 'generateAccessToken' "$STUB_LOG"
}

@test "GOOGLE_APPLICATION_CREDENTIALS is exported for later steps" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  grep -q "GOOGLE_APPLICATION_CREDENTIALS=$(config_file)" "$GITHUB_ENV"
}

@test "a project id sets both variables, because the provider and gcloud read different ones" {
  GCP_PROJECT_ID=my-proj run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  grep -q '^GOOGLE_PROJECT=my-proj$' "$GITHUB_ENV"
  grep -q '^GOOGLE_CLOUD_PROJECT=my-proj$' "$GITHUB_ENV"
}

@test "an STS refusal names the attribute condition rather than the plan that would have failed" {
  STS_FAILS=true run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"attribute condition"* ]]
}

@test "a refused impersonation is told apart from a refused federation, they have different fixes" {
  GCP_SERVICE_ACCOUNT=ci@proj.iam.gserviceaccount.com IMPERSONATION_FAILS=true \
    run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"roles/iam.workloadIdentityUser"* ]]
  refute grep -q 'attribute condition' <<<"$output"
}

@test "an empty OIDC token is a failure, not an empty credential file" {
  OIDC_TOKEN= run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty OIDC token"* ]]
}

@test "the minted token carries the provider's own audience by default" {
  run bash "${SCRIPTS}/gcp-login.sh"
  [ "$status" -eq 0 ]
  grep -q "audience=https://iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}" "$STUB_LOG"
}
