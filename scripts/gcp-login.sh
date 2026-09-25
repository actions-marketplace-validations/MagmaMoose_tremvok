#!/usr/bin/env bash
# Exchange this run's GitHub OIDC token for Google Cloud credentials.
#
# The third of the set, and the same argument as `assume-role.sh` and `azure-login.sh`: no
# service-account key is stored in any repository. GitHub mints a token for this run, Google's
# STS trades it for a federated one, and the workload identity pool's attribute condition
# decides which repository and which ref may do that. A downloaded service-account key is the
# opposite — a long-lived file, valid until somebody remembers to delete it, tied to nothing,
# and the thing workload identity federation exists to end.
#
# Deliberately not `google-github-actions/auth`, for the reason this repository does not use
# `aws-actions/configure-aws-credentials` or `azure/login` either: a third-party action inside
# the step that holds production credentials. A caller who prefers it runs it in an earlier
# step and leaves `gcp-workload-identity-provider` empty.
#
# WHAT IT WRITES, AND WHY IT IS TWO FILES. Google's client libraries do not take a token; they
# take a *credential configuration* that tells them where to find one and what to exchange it
# for. So this writes the OIDC token to one file and a small `external_account` JSON pointing
# at it to another, and exports GOOGLE_APPLICATION_CREDENTIALS. The Terraform google provider
# reads that variable like every other Google client. Both files land in RUNNER_TEMP at 0600;
# the token one is a live bearer credential for its short lifetime.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

WORKLOAD_IDENTITY_PROVIDER="${WORKLOAD_IDENTITY_PROVIDER:-}"
GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT:-}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
CREDENTIAL_DIR="${CREDENTIAL_DIR:-${RUNNER_TEMP:-/tmp}}"
# The `aud` the pool's provider is created with. Fixed to the provider's own resource URL,
# which is Google's default, and overridable because a provider created with a custom audience
# rejects the default one with an error that names neither side.
GCP_AUDIENCE="${GCP_AUDIENCE:-}"
STS_URL="${STS_URL:-https://sts.googleapis.com/v1/token}"
IAM_CREDENTIALS_HOST="${IAM_CREDENTIALS_HOST:-https://iamcredentials.googleapis.com}"

if [[ -z "$WORKLOAD_IDENTITY_PROVIDER" ]]; then
  tremvok::log "no gcp-workload-identity-provider; using whatever Google credentials the job already has"
  exit 0
fi

# The full resource name, not the pool and not a URL. Refused here rather than at the exchange,
# where Google answers with a 400 about an invalid audience and names nothing that helps.
case "$WORKLOAD_IDENTITY_PROVIDER" in
  projects/*/locations/*/workloadIdentityPools/*/providers/*) ;;
  *) tremvok::fail "gcp-workload-identity-provider must be the provider's full resource name, 'projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>' (got '${WORKLOAD_IDENTITY_PROVIDER}')." ;;
esac

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  tremvok::fail "gcp-workload-identity-provider is set but this job cannot mint an OIDC token. Add 'permissions: id-token: write' to the workflow."
fi

[[ -n "$GCP_AUDIENCE" ]] || GCP_AUDIENCE="https://iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}"

token="$(curl --silent --show-error --fail --max-time 15 \
  --header "authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${GCP_AUDIENCE}" | jq -r '.value // empty')" \
  || tremvok::fail "could not mint an OIDC token for audience '${GCP_AUDIENCE}'"
[[ -n "$token" ]] || tremvok::fail "GitHub returned an empty OIDC token"

# Masked before it is written anywhere. The token is a bearer credential for the pool's
# lifetime, and every tool downstream is perfectly capable of echoing its own config on error.
printf '::add-mask::%s\n' "$token"

token_file="${CREDENTIAL_DIR}/tremvok-gcp-oidc-token"
config_file="${CREDENTIAL_DIR}/tremvok-gcp-credentials.json"

# Created empty at 0600 BEFORE anything is written to it. `printf > file` creates it with the
# umask's permissions and narrows it afterwards, which leaves a window where the token is
# world-readable on a shared self-hosted runner — and a self-hosted runner is exactly where
# this matters.
for f in "$token_file" "$config_file"; do
  : >"$f"
  chmod 600 "$f"
done
printf '%s' "$token" >"$token_file"

# `jq -n`, not a heredoc: the service-account email and the provider name are interpolated,
# and a hand-written JSON template is how an unescaped character becomes a config the client
# library rejects with a parse error naming a byte offset.
impersonation_url=""
if [[ -n "$GCP_SERVICE_ACCOUNT" ]]; then
  impersonation_url="${IAM_CREDENTIALS_HOST}/v1/projects/-/serviceAccounts/${GCP_SERVICE_ACCOUNT}:generateAccessToken"
fi

jq -n \
  --arg audience "//iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}" \
  --arg token_url "$STS_URL" \
  --arg token_file "$token_file" \
  --arg impersonation "$impersonation_url" \
  '{
     universe_domain: "googleapis.com",
     type: "external_account",
     audience: $audience,
     subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
     token_url: $token_url,
     credential_source: { file: $token_file, format: { type: "text" } }
   }
   + (if $impersonation == "" then {} else { service_account_impersonation_url: $impersonation } end)' \
  >"$config_file"

# ── prove the federation is accepted, here, rather than in the first plan ─────────────────
# The two failures worth separating, because they read alike from inside Terraform and have
# completely different fixes:
#
#   * the pool's attribute condition does not match this repository or ref — STS refuses;
#   * it matches, but the external identity has no roles/iam.workloadIdentityUser on the
#     service account — STS is happy and the impersonation is refused.
#
# One call each. Neither result is kept: the credential the providers use is the config file,
# and an access token printed anywhere is an access token in a log.
federated="$(curl --silent --show-error --max-time 20 \
  --request POST "$STS_URL" \
  --header 'content-type: application/json' \
  --data "$(jq -n --arg a "//iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}" --arg t "$token" '{
      audience: $a,
      grantType: "urn:ietf:params:oauth:grant-type:token-exchange",
      requestedTokenType: "urn:ietf:params:oauth:token-type:access_token",
      scope: "https://www.googleapis.com/auth/cloud-platform",
      subjectTokenType: "urn:ietf:params:oauth:token-type:jwt",
      subjectToken: $t
    }')" 2>/dev/null || printf '')"

access_token="$(jq -r '.access_token // empty' <<<"$federated" 2>/dev/null || printf '')"
if [[ -z "$access_token" ]]; then
  detail="$(jq -r '.error_description // .error.message // empty' <<<"$federated" 2>/dev/null || printf '')"
  tremvok::fail "Google STS refused the OIDC token for ${WORKLOAD_IDENTITY_PROVIDER}${detail:+ — ${detail}}. Check the pool provider's issuer URI and its attribute condition allow this repository and ref, and that the audience is '${GCP_AUDIENCE}'."
fi
printf '::add-mask::%s\n' "$access_token"

if [[ -n "$GCP_SERVICE_ACCOUNT" ]]; then
  impersonated="$(curl --silent --show-error --max-time 20 \
    --request POST "$impersonation_url" \
    --header "authorization: Bearer ${access_token}" \
    --header 'content-type: application/json' \
    --data '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' 2>/dev/null || printf '')"
  if [[ -z "$(jq -r '.accessToken // empty' <<<"$impersonated" 2>/dev/null || printf '')" ]]; then
    detail="$(jq -r '.error.message // empty' <<<"$impersonated" 2>/dev/null || printf '')"
    tremvok::fail "the federated identity may not impersonate ${GCP_SERVICE_ACCOUNT}${detail:+ — ${detail}}. Grant the pool's principalSet roles/iam.workloadIdentityUser on that service account."
  fi
  printf '::add-mask::%s\n' "$(jq -r '.accessToken' <<<"$impersonated")"
fi

{
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\n' "$config_file"
  # Both, because the google provider reads GOOGLE_PROJECT and gcloud reads
  # GOOGLE_CLOUD_PROJECT, and a run that sets one is a run where half the tools guess.
  [[ -n "$GCP_PROJECT_ID" ]] && printf 'GOOGLE_PROJECT=%s\nGOOGLE_CLOUD_PROJECT=%s\n' "$GCP_PROJECT_ID" "$GCP_PROJECT_ID"
} >>"${GITHUB_ENV:-/dev/null}"

# GITHUB_ENV only reaches later steps, and terragrunt-credentials.sh runs inside one of them,
# so this shell exports it too for anything that runs here.
export GOOGLE_APPLICATION_CREDENTIALS="$config_file"

tremvok::log "federated with ${WORKLOAD_IDENTITY_PROVIDER}${GCP_SERVICE_ACCOUNT:+ as ${GCP_SERVICE_ACCOUNT}}"
