#!/usr/bin/env bash
# Does this runner hold a credential for every cloud this stack's providers name?
#
# A terragrunt run needs more than one credential and they come from different places, which
# is why this is the least readable failure in the whole action. The STATE BACKEND has one,
# supplied per stack by `terragrunt-stack-env` — an ARM_ACCESS_KEY, an AWS role, a GCS key.
# Every `provider` block the configuration declares has ANOTHER, resolved by that provider's
# own chain, which nothing in the workflow mentions. Get the first and not the second and the
# run does not fail early or clearly: `terragrunt init` reads and writes state perfectly well,
# the plan starts, and then every stack in turn dies with
#
#   unable to build authorizer for Resource Manager API: could not configure AzureCli
#   Authorizer: ... running Azure CLI: exit status 1: ERROR: Please run 'az login'
#
# twenty times, with a line number in a `provider.tf` that a `generate` block wrote and nobody
# has ever opened. That reads as a broken runner. It is a credential nobody wired.
#
# PROVIDERS ONLY, DELIBERATELY. The backend's credential is not checked here and does not need
# to be: a backend without one fails in `init`, immediately, naming the backend — the good
# failure. `terragrunt-preflight-urls` already covers whether the backend is reachable at all.
# Adding the backend to this would mean deciding whether an ARM_ACCESS_KEY counts as an Azure
# credential, and it does not: it opens one storage account and cannot configure a provider.
#
# WHAT IT PROVES: a credential is present. Not that it is valid, not that it reaches the
# subscription, project or account the stack names — the same line `preflight-urls.sh` draws
# between reachable and authorised. A check that promised more would have to make the calls
# the plan is about to make anyway.
#
# Usage: terragrunt-credentials.sh <stack-dir>
# Run it with the stack's own environment applied, exactly as its plan will be: a credential
# that arrives through `terragrunt-stack-env` is invisible to a check run without it, and
# reporting it missing is the false alarm that gets a check deleted.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT_DIR="${ROOT_DIR:-terraform}"
# Overridable so bats can put a recorder in front of them; production uses whatever is on PATH.
AZ_BIN="${AZ_BIN:-az}"
AWS_BIN="${AWS_BIN:-aws}"
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"

stack="${1:-}"
[[ -n "$stack" ]] || tremvok::fail "usage: terragrunt-credentials.sh <stack-dir>"
[[ -d "$stack" ]] || tremvok::fail "terragrunt-credentials.sh: no such stack directory: ${stack}"

# ── which files describe this stack's providers ──────────────────────────────────────────
# The stack's own directory and every ancestor up to ROOT_DIR. The ancestors are not
# optional and they are where the answer usually lives: `include { path = find_in_parent_
# folders() }` is the normal Terragrunt shape, and a shared root.hcl generating `provider.tf`
# for the whole tree means the stack directory itself declares no provider at all.
#
# `-maxdepth 1`, so a stack does not inherit a sibling's providers by being above it.
stack_files() {
  local dir="$1" parent
  while :; do
    find "$dir" -maxdepth 1 -type f \( -name '*.tf' -o -name '*.hcl' \) 2>/dev/null || true
    [[ "$dir" == "$ROOT_DIR" ]] && break
    parent="$(dirname "$dir")"
    # `.` and `/` end the walk for a stack that is not under ROOT_DIR at all, which would
    # otherwise climb to the filesystem root reading whatever it found.
    case "$parent" in
      "$dir" | . | /) break ;;
    esac
    dir="$parent"
  done
}

# ── the provider block, brace-counted ────────────────────────────────────────────────────
# Textual, and that is a deliberate limit rather than an oversight: the block this most needs
# to read is usually inside a `contents = <<EOF ... EOF` heredoc in a root.hcl, where no HCL
# parser will look and where `terragrunt render-json` would need a full evaluation — every
# variable, every dependency output, before the first plan. A brace count reads it as written.
# A `{` inside a string literal would miscount; provider blocks do not have one.
provider_block() { # provider-name < files
  local want="$1"
  awk -v want="$want" '
    BEGIN { inblock = 0; depth = 0 }
    {
      line = $0
      if (!inblock) {
        if (line ~ ("^[[:space:]]*provider[[:space:]]+\"" want "\"")) { inblock = 1; depth = 0 }
        else next
      }
      print line
      # gsub returns the count and edits its target, so it runs on the copy, after the print.
      o = gsub(/\{/, "{", line)
      c = gsub(/\}/, "}", line)
      depth += o - c
      if (depth <= 0) inblock = 0
    }
  '
}

# The clouds this action has an opinion about. Anything else is passed over in silence: a
# check that guesses at a provider it does not know is a check that blocks a run for a reason
# it cannot explain, and the next person turns it off for every provider at once.
cloud_for_provider() { # provider-name
  case "$1" in
    azurerm | azuread | azapi | azurestack) printf 'azure' ;;
    aws | awscc) printf 'aws' ;;
    google | google-beta) printf 'gcp' ;;
    vcd) printf 'vcd' ;;
    *) printf '' ;;
  esac
}

# An argument in the block that means "this configuration brings its own credential". Matched
# as an argument name at the head of a line, so a `subscription_id` or a comment mentioning
# one of these words does not exempt a block that in fact authenticates by CLI.
#
# `use_cli` is deliberately NOT here. It selects the Azure CLI chain, which is the very thing
# this check asks about, so treating it as self-configured auth would exempt exactly the case
# that fails.
self_configures_auth() { # cloud < block
  local cloud="$1" keys
  case "$cloud" in
    azure) keys='client_id|client_secret|client_certificate|client_certificate_path|oidc_token|oidc_token_file_path|oidc_request_token|use_oidc|use_msi|msi_endpoint|use_aks_workload_identity' ;;
    aws)   keys='access_key|secret_key|profile|token|assume_role|assume_role_with_web_identity|shared_credentials_files|shared_config_files' ;;
    gcp)   keys='credentials|access_token|impersonate_service_account' ;;
    vcd)   keys='user|password|api_token|api_token_file|auth_type|service_account_token_file' ;;
    *)     return 1 ;;
  esac
  grep -Eq "^[[:space:]]*(${keys})[[:space:]]*=" || return 1
  return 0
}

# ── is there a credential for this cloud ─────────────────────────────────────────────────
# Environment first, CLI second: the environment is free to read and the CLI probe is not, and
# a runner carrying a service principal in its environment has answered the question already.
#
# Each returns 0 when something is present, and says nothing about whether it works.
azure_has_credential() {
  if tremvok::is_true "${ARM_USE_MSI:-}" || tremvok::is_true "${ARM_USE_OIDC:-}" || tremvok::is_true "${ARM_USE_AKS_WORKLOAD_IDENTITY:-}"; then
    return 0
  fi
  if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
    if [[ -n "${ARM_CLIENT_SECRET:-}" || -n "${ARM_CLIENT_CERTIFICATE:-}" \
       || -n "${ARM_CLIENT_CERTIFICATE_PATH:-}" || -n "${ARM_OIDC_TOKEN:-}" \
       || -n "${ARM_OIDC_TOKEN_FILE_PATH:-}" ]]; then
      return 0
    fi
  fi
  # `az account show` reads the token cache `az login` wrote. It is the only honest probe of
  # the chain the provider actually uses, and it is the one that answers "signed in", not
  # "the CLI exists" — a runner with `az` installed and nobody signed in is the failure.
  if command -v "$AZ_BIN" >/dev/null 2>&1 && "$AZ_BIN" account show --output none >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

aws_has_credential() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" || -n "${AWS_PROFILE:-}" \
     || -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" || -n "${AWS_ROLE_ARN:-}" \
     || -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" \
     || -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]]; then
    return 0
  fi
  # The only case the environment cannot answer: an instance profile, where the credential
  # lives at the metadata endpoint and nothing is exported. Self-hosted runners are exactly
  # where that shape is normal, so the probe is not optional.
  if command -v "$AWS_BIN" >/dev/null 2>&1 && "$AWS_BIN" sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

gcp_has_credential() {
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" || -n "${GOOGLE_CREDENTIALS:-}" \
     || -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" || -n "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]]; then
    return 0
  fi
  if command -v "$GCLOUD_BIN" >/dev/null 2>&1 \
    && [[ -n "$("$GCLOUD_BIN" auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

vcd_has_credential() {
  if [[ -n "${VCD_API_TOKEN:-}" || -n "${VCD_API_TOKEN_FILE:-}" \
     || -n "${VCD_SA_TOKEN_FILE:-}" ]]; then
    return 0
  fi
  if [[ -n "${VCD_USER:-}" && -n "${VCD_PASSWORD:-}" ]]; then
    return 0
  fi
  return 1
}

has_credential() { # cloud
  case "$1" in
    azure) azure_has_credential ;;
    aws) aws_has_credential ;;
    gcp) gcp_has_credential ;;
    vcd) vcd_has_credential ;;
    *) return 0 ;;
  esac
}

# What to do about it, in the caller's own terms. The message is the whole point of the check:
# the error it replaces is accurate and unactionable.
remedy_for() { # cloud
  case "$1" in
    azure) printf '%s' "set azure-client-id, azure-tenant-id and azure-subscription-id (the action signs in with this run's OIDC token), run azure/login in an earlier step, or hand the stack ARM_CLIENT_ID and a secret through terragrunt-stack-env. ARM_ACCESS_KEY is the state backend's credential and does not configure the provider." ;;
    aws) printf '%s' "set aws-role-to-assume (OIDC, preferred), or configure credentials in an earlier step." ;;
    gcp) printf '%s' "run google-github-actions/auth in an earlier step, or hand the stack GOOGLE_CREDENTIALS through terragrunt-stack-env." ;;
    vcd) printf '%s' "hand the stack VCD_API_TOKEN, or VCD_USER and VCD_PASSWORD, through terragrunt-stack-env." ;;
    *) printf '%s' "configure a credential for it." ;;
  esac
}

# ── detect, then check ───────────────────────────────────────────────────────────────────
files="$(stack_files "$stack")"
if [[ -z "$files" ]]; then
  tremvok::log "  ${stack}: no .tf or .hcl files to read; nothing to check"
  exit 0
fi

# Read once, into one string. A loop rather than `grep $files`: an unquoted list of paths is
# split on whitespace, and the one directory in an infrastructure monorepo with a space in its
# name would make this read the wrong files and say so about the wrong stack.
content="$(
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    cat "$file" 2>/dev/null || true
    printf '\n'
  done <<<"$files"
)"

providers="$(
  printf '%s\n' "$content" \
    | grep -Eo '^[[:space:]]*provider[[:space:]]+"[A-Za-z0-9_-]+"' \
    | sed -E 's/.*"([A-Za-z0-9_-]+)".*/\1/' \
    | sort -u || true
)"

if [[ -z "$providers" ]]; then
  tremvok::log "  ${stack}: declares no provider block; nothing to check"
  exit 0
fi

# The machine-readable half, for the caller that aggregates across stacks. Separate from
# stdout on purpose: stdout is the run log a person reads, and a format that is both is a
# format that breaks the moment somebody improves a sentence.
REPORT="${CREDENTIAL_REPORT:-}"

missing=0
checked=""
while IFS= read -r provider; do
  [[ -n "$provider" ]] || continue
  cloud="$(cloud_for_provider "$provider")"
  [[ -n "$cloud" ]] || continue

  if provider_block "$provider" <<<"$content" | self_configures_auth "$cloud"; then
    tremvok::log "  ${stack}: provider \"${provider}\" configures its own authentication; not checked"
    continue
  fi

  # One verdict per cloud per stack: azurerm and azuread are one credential, and reporting it
  # twice makes a two-line failure look like two problems. The dedup runs after the exemption
  # check so a self-configuring azuread does not stand in for a default-chain azurerm.
  case " ${checked} " in
    *" ${cloud} "*) continue ;;
  esac
  checked="${checked}${cloud} "

  if has_credential "$cloud"; then
    tremvok::log "  ${stack}: ${cloud} (provider \"${provider}\") — credential present"
  else
    tremvok::log "  ${stack}: ${cloud} (provider \"${provider}\") — NO CREDENTIAL on this runner"
    missing=$(( missing + 1 ))
    if [[ -n "$REPORT" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$cloud" "$stack" "$provider" "$(remedy_for "$cloud")" >>"$REPORT"
    fi
  fi
done <<<"$providers"

(( missing == 0 )) || exit 1
exit 0
