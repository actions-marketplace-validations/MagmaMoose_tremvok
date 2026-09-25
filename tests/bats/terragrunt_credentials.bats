#!/usr/bin/env bats
#
# The provider-credential preflight. Three properties matter, and they pull against each
# other, which is why they are tested together:
#
#   * it must FIND the provider, including the common case where the only declaration is a
#     heredoc inside a shared root.hcl several directories above the stack;
#   * it must not fire on a stack that brings its own credential, because one false alarm on
#     an estate-wide plan is what gets a guard like this switched off for good;
#   * it must read the STACK's environment, not the job's, because `terragrunt-stack-env` is
#     where a per-stack credential arrives.

load helper

setup() {
  setup_common
  export ROOT_DIR="${WORK}/terraform"
  mkdir -p "${ROOT_DIR}/azure/non-prod/aks"
  export STACK="${ROOT_DIR}/azure/non-prod/aks"
  printf 'include "root" {\n  path = find_in_parent_folders("root.hcl")\n}\n' >"${STACK}/terragrunt.hcl"

  # Nothing signed in, nothing in the environment: the default state of a fresh runner.
  export AZ_BIN="${STUB_BIN}/az"
  export AWS_BIN="${STUB_BIN}/aws"
  export GCLOUD_BIN="${STUB_BIN}/gcloud"
  stub az 1 ''
  stub aws 1 ''
  stub gcloud 0 ''
  unset ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_USE_OIDC ARM_USE_MSI || true
  unset AWS_ACCESS_KEY_ID AWS_PROFILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE || true
  unset GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CREDENTIALS || true
  unset VCD_API_TOKEN VCD_USER VCD_PASSWORD || true

  export CREDENTIAL_REPORT="${WORK}/report.tsv"
  : >"$CREDENTIAL_REPORT"
}

# The shape this whole check exists for: root.hcl generates provider.tf, so the provider is
# declared inside a heredoc, in a file two directories above the stack, and the stack's own
# directory says nothing about Azure at all.
generate_block_root() {
  cat >"${ROOT_DIR}/azure/root.hcl" <<'HCL'
remote_state {
  backend = "azurerm"
  config = {
    storage_account_name = "samtfstate"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}
EOF
}
HCL
}

@test "a generated azurerm provider in a parent root.hcl is found, and reported missing" {
  generate_block_root
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO CREDENTIAL"* ]]
  grep -q '^azure' "$CREDENTIAL_REPORT"
}

@test "the remedy names the backend/provider distinction, which is the actual confusion" {
  generate_block_root
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  grep -q 'ARM_ACCESS_KEY is the state backend' "$CREDENTIAL_REPORT"
}

@test "a signed-in az satisfies it" {
  generate_block_root
  stub az 0 ''
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"credential present"* ]]
  [ ! -s "$CREDENTIAL_REPORT" ]
}

@test "az installed but nobody signed in is the failure, not a pass" {
  # `command -v az` succeeding is not the question. The stub exits non-zero for
  # `account show`, which is what an unauthenticated CLI does.
  generate_block_root
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
}

@test "a service principal in the environment satisfies it without calling the CLI" {
  generate_block_root
  ARM_CLIENT_ID=11111111-2222-3333-4444-555555555555 ARM_CLIENT_SECRET=shhh \
    run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  refute grep -q 'account show' "$STUB_LOG"
}

@test "a provider block that configures its own auth is not checked" {
  # The false-positive case. A provider reading a client id from a variable authenticates
  # itself, and reporting it missing is how a guard gets turned off for every provider.
  cat >"${STACK}/provider.tf" <<'HCL'
provider "azurerm" {
  client_id     = var.client_id
  client_secret = var.client_secret
  features {}
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"configures its own authentication"* ]]
}

@test "use_cli does NOT count as configuring its own auth" {
  # It selects the chain this check asks about, so exempting on it would exempt the one
  # case that fails.
  cat >"${STACK}/provider.tf" <<'HCL'
provider "azurerm" {
  use_cli = true
  features {}
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
}

@test "subscription_id alone does not exempt a block, it is not a credential" {
  generate_block_root
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
}

@test "azurerm and azuread are one credential and are reported once" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "azurerm" {
  features {}
}

provider "azuread" {
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^azure' "$CREDENTIAL_REPORT")" -eq 1 ]
}

@test "an unrecognised provider is passed over in silence" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "kubernetes" {
  config_path = "~/.kube/config"
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  [ ! -s "$CREDENTIAL_REPORT" ]
}

@test "a stack with no provider block at all is not a failure" {
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no provider block"* ]]
}

@test "the walk stops at ROOT_DIR and does not read a sibling stack's providers" {
  mkdir -p "${ROOT_DIR}/azure/non-prod/other"
  cat >"${ROOT_DIR}/azure/non-prod/other/provider.tf" <<'HCL'
provider "google" {
  project = "x"
}
HCL
  cat >"${STACK}/provider.tf" <<'HCL'
provider "azurerm" {
  features {}
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  refute grep -q '^gcp' "$CREDENTIAL_REPORT"
}

@test "vcd is satisfied by an api token, which is how terragrunt-stack-env delivers one" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "vcd" {
  url = "https://vcd.example.com/api"
}
HCL
  VCD_API_TOKEN=token run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
}

@test "vcd with nothing set is reported" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "vcd" {
  url = "https://vcd.example.com/api"
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  grep -q '^vcd' "$CREDENTIAL_REPORT"
}

@test "aws is satisfied by an instance profile the environment cannot see" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "aws" {
  region = "eu-west-1"
}
HCL
  stub aws 0 '{}'
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
  grep -q 'sts get-caller-identity' "$STUB_LOG"
}

@test "gcp is satisfied by an active gcloud account" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "google" {
  project = "x"
}
HCL
  stub gcloud 0 'ci@example.iam.gserviceaccount.com'
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -eq 0 ]
}

@test "gcp with gcloud present but no active account is reported" {
  cat >"${STACK}/provider.tf" <<'HCL'
provider "google" {
  project = "x"
}
HCL
  stub gcloud 0 ''
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  grep -q '^gcp' "$CREDENTIAL_REPORT"
}

@test "a missing stack directory is a usage error, not a silent pass" {
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "${WORK}/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such stack directory"* ]]
}

@test "a self-configured azuread does not exempt a default-chain azurerm in the same stack" {
  # The dedup/exemption ordering bug: providers are sorted, so azuread < azurerm.
  # A self-configuring azuread would mark the whole azure cloud checked and skip azurerm,
  # which actually relies on the CLI — exactly the failure this script exists to catch.
  cat >"${STACK}/provider.tf" <<'HCL'
provider "azuread" {
  client_id     = var.client_id
  use_oidc      = true
}

provider "azurerm" {
  features {}
}
HCL
  run bash "${SCRIPTS}/terragrunt-credentials.sh" "$STACK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NO CREDENTIAL"* ]]
  grep -q '^azure' "$CREDENTIAL_REPORT"
}
