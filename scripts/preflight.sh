#!/usr/bin/env bash
# Decide whether this run can deploy at all, and skip *loudly* when it cannot.
#
# Two situations produce a confusing red job in every hand-rolled deploy workflow in the fleet:
#
#   * a pull request from a fork, which cannot read secrets — so the AWS credential is empty
#     and the deploy fails with an authentication error that looks like a broken credential
#     rather than a policy that is working as designed;
#   * a repository that has adopted the workflow but not yet been wired to a role, where the
#     same thing happens for a different reason.
#
# Both are expected states, so both become a skip with a reason on the job summary. dunmir's
# planner does this for Cloudflare; this is that generalised, because "honest skip over
# confusing failure" only works if it covers every reason to skip.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IS_FORK="${IS_FORK:-false}"
ROLE_TO_ASSUME="${ROLE_TO_ASSUME:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_WEB_IDENTITY_TOKEN_FILE="${AWS_WEB_IDENTITY_TOKEN_FILE:-}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
TARGET="${TARGET:-}"
ALLOW_FORK_PREVIEW="${ALLOW_FORK_PREVIEW:-false}"

skip=false
reason=""

if tremvok::is_true "$IS_FORK" && ! tremvok::is_true "$ALLOW_FORK_PREVIEW"; then
  skip=true
  reason="this pull request comes from a fork, so the workflow cannot read the deployment credential. Nothing was deployed, and that is the intended behaviour — a fork must not be able to publish."
elif [[ "$TARGET" == "s3-cloudfront" || "$TARGET" == "lambda-zip" ]] \
  && [[ -z "$ROLE_TO_ASSUME" && -z "$AWS_ACCESS_KEY_ID" && -z "$AWS_WEB_IDENTITY_TOKEN_FILE" ]]; then
  # Only the two targets that call AWS themselves. Every other target publishes somewhere
  # else: github-pages to Pages, cloudflare-workers to Cloudflare, ansible to hosts over SSH.
  # terragrunt is the one that looks like an AWS target and is not. It is provider-agnostic:
  # its credentials come from the backend and provider blocks its own configuration names,
  # which may be AWS, Azure, GCP, a private cloud, or several of them in one run, and
  # terragrunt-stack-env exists to carry exactly those. Demanding an AWS credential from any
  # of these skips a run that was never going to need one, which is an honest skip that is
  # simply wrong. A terragrunt run that genuinely needed AWS fails in the provider instead,
  # with a message naming the provider, and that is the better message of the two.
  skip=true
  reason="no AWS credential is available for target: ${TARGET}. Set aws-role-to-assume (OIDC, preferred) or configure credentials in an earlier step. Nothing was deployed."
elif [[ "$TARGET" == "azure-functions-zip" || "$TARGET" == "azure-apim-policy" ]] \
  && [[ -z "$AZURE_CLIENT_ID" && -z "$AZURE_SUBSCRIPTION_ID" && ! -d "${HOME:-/nonexistent}/.azure" ]]; then
  # The Azure equivalent, and the ambient case is a directory rather than a variable: a
  # session `az login` created in an earlier step lives in ~/.azure, not in the environment.
  # Checking for it is what keeps "run azure/login yourself first" a supported way to use
  # this target rather than a configuration that skips for no visible reason.
  skip=true
  reason="no Azure credential is available for target: ${TARGET}. Set azure-client-id, azure-tenant-id and azure-subscription-id (OIDC, preferred) or sign in during an earlier step. Nothing was deployed."
fi

if [[ "$skip" == true ]]; then
  tremvok::notice "Tremvok skipped: ${reason}"
  tremvok::summary "## Tremvok — skipped"
  tremvok::summary ""
  tremvok::summary "${reason}"
else
  tremvok::log "preflight ok for target=${TARGET:-<unset>}"
fi

tremvok::set_output skip "$skip"
tremvok::set_output skip-reason "$reason"
