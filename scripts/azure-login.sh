#!/usr/bin/env bash
# Exchange this run's GitHub OIDC token for an Azure CLI session.
#
# The Azure half of the argument `assume-role.sh` makes for AWS: no client secret and no
# publish profile is stored in any repository. GitHub mints a token for this run, Entra ID
# trades it for a session, and the app registration's *federated credential* decides which
# repository, and which ref or environment, may do that. A publish profile is the opposite
# of this — a long-lived credential, downloadable as a file, carrying the deployment rights
# of the whole site, with nothing tying it to a repository. It is also why the Functions
# quickstarts read the way they do, which is not a reason to copy them.
#
# Deliberately not `azure/login`, for the same reason this repository does not use
# `aws-actions/configure-aws-credentials`: a third-party action inside the step that holds
# production credentials, for an exchange that is one `az login` call. A caller who prefers
# it can run it in an earlier step and leave `azure-client-id` empty — `preflight.sh`
# accepts an ambient session, exactly as it does for AWS.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
# The audience Entra ID expects on a workload-identity federated credential. Fixed rather
# than an input: it is the audience the federated credential is created with, and a value
# that disagrees fails at login with an error that names neither side.
AZURE_AUDIENCE="${AZURE_AUDIENCE:-api://AzureADTokenExchange}"
# Overridable so bats can put a recorder in front of it.
AZ_BIN="${AZ_BIN:-az}"

if [[ -z "$AZURE_CLIENT_ID" ]]; then
  tremvok::log "no azure-client-id; using whatever Azure session the job already has"
  exit 0
fi

tremvok::require AZURE_TENANT_ID "azure-tenant-id, without which the login has no directory to authenticate against"
tremvok::require AZURE_SUBSCRIPTION_ID "azure-subscription-id, without which the CLI has no default subscription and every later command needs one"

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  tremvok::fail "azure-client-id is set but this job cannot mint an OIDC token. Add 'permissions: id-token: write' to the workflow."
fi

token="$(curl --silent --show-error --fail --max-time 15 \
  --header "authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AZURE_AUDIENCE}" | jq -r '.value // empty')" \
  || tremvok::fail "could not mint an OIDC token for audience '${AZURE_AUDIENCE}'"
[[ -n "$token" ]] || tremvok::fail "GitHub returned an empty OIDC token"

# Masked before it is used, not after. The token is a bearer credential for the federated
# credential's lifetime, and `az` is perfectly capable of echoing its own arguments back in
# an error message.
printf '::add-mask::%s\n' "$token"

# `--federated-token`, not `--password`: the first is the workload-identity exchange, the
# second is a client secret, and passing a token as a secret fails in a way that reads like
# a wrong password rather than a wrong flag.
"$AZ_BIN" login --service-principal \
  --username "$AZURE_CLIENT_ID" \
  --tenant "$AZURE_TENANT_ID" \
  --federated-token "$token" \
  --output none \
  || tremvok::fail "Entra ID refused the federated token for client ${AZURE_CLIENT_ID}. Check the app registration has a federated credential for this repository and ref, and that the audience is ${AZURE_AUDIENCE}."

"$AZ_BIN" account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none \
  || tremvok::fail "could not select subscription ${AZURE_SUBSCRIPTION_ID}. Check the service principal has a role assignment on it."

tremvok::log "signed in to Azure as ${AZURE_CLIENT_ID} on subscription ${AZURE_SUBSCRIPTION_ID}"
