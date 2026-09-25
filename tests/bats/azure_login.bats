#!/usr/bin/env bats
#
# The Azure half of assume_role.bats, and the same three things matter: it must not leak the
# token into a log, it must fail loudly when the workflow forgot `id-token: write`, and it
# must do nothing at all when no client id is configured — because "do nothing" is what makes
# `azure/login` in an earlier step a supported way to use this target.

load helper

setup() {
  setup_common
  export GITHUB_REPOSITORY=samenlevingszaken/ghreceiver
  export GITHUB_RUN_ID=12345
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.test/?foo=bar'
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  export AZURE_CLIENT_ID=11111111-2222-3333-4444-555555555555
  export AZURE_TENANT_ID=66666666-7777-8888-9999-000000000000
  export AZURE_SUBSCRIPTION_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
printf '{"value":"%s"}' "${OIDC_TOKEN-header.payload.s3cr3t-federated-token}"
STUBEOF

  export AZ_BIN="${STUB_BIN}/az"
  stub_script az <<'STUBEOF'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >>"${STUB_LOG}"
case "$*" in
  *login*)       [ "${LOGIN_FAILS:-false}" = "true" ] && exit 1 ;;
  *"account set"*) [ "${ACCOUNT_SET_FAILS:-false}" = "true" ] && exit 1 ;;
esac
exit 0
STUBEOF
}

@test "no client id is a no-op, not a failure" {
  AZURE_CLIENT_ID= run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a client id without id-token: write fails with the fix in the message" {
  ACTIONS_ID_TOKEN_REQUEST_URL= run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

@test "the federated token is masked before it is handed to the CLI" {
  # Without ::add-mask::, an `az` that echoes its own arguments back in an error — which it
  # does — prints a live bearer credential into a log anyone with read access keeps.
  run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -eq 0 ]
  mask_line="$(grep -n '::add-mask::header.payload.s3cr3t-federated-token' <<<"$output" | cut -d: -f1)"
  login_line="$(grep -n 'signed in to Azure' <<<"$output" | cut -d: -f1)"
  [ -n "$mask_line" ]
  [ "$mask_line" -lt "$login_line" ]
}

@test "the exchange asks for the audience Entra ID federated credentials expect" {
  # A federated credential is created with this audience. A token minted for another one is
  # refused at login with a message that names neither side.
  run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -eq 0 ]
  grep -q 'audience=api://AzureADTokenExchange' "$STUB_LOG"
}

@test "it signs in with --federated-token, never --password" {
  # `--password` is the client-secret flow. Passing a federated token to it fails in a way
  # that reads like a wrong secret rather than a wrong flag.
  run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--federated-token" "$STUB_LOG"
  refute grep -q -- "--password" "$STUB_LOG"
}

@test "the subscription is selected, so later commands do not need one" {
  run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -eq 0 ]
  grep -q -- "account set --subscription aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$STUB_LOG"
}

@test "a client id with no tenant is refused before the token is minted" {
  AZURE_TENANT_ID= run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AZURE_TENANT_ID is required"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a client id with no subscription is refused before the token is minted" {
  AZURE_SUBSCRIPTION_ID= run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AZURE_SUBSCRIPTION_ID is required"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a refused login names the federated credential as the thing to check" {
  LOGIN_FAILS=true run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"federated credential for this repository and ref"* ]]
}

@test "an empty token from GitHub is a failure, not an empty login" {
  OIDC_TOKEN= run bash "${SCRIPTS}/azure-login.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty OIDC token"* ]]
}
