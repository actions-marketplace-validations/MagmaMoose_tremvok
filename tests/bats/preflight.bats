#!/usr/bin/env bats

load helper
setup() { setup_common; unset AWS_ACCESS_KEY_ID AWS_WEB_IDENTITY_TOKEN_FILE; }

@test "a fork pull request skips with a reason, not an auth error" {
  IS_FORK=true ROLE_TO_ASSUME=arn:aws:iam::1:role/x run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"fork"* ]]
  grep -q "Tremvok — skipped" "$GITHUB_STEP_SUMMARY"
}

@test "an unwired repository skips with a reason" {
  IS_FORK=false TARGET=s3-cloudfront ROLE_TO_ASSUME= run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"no AWS credential"* ]]
}

@test "a target that never touches AWS is not skipped for want of an AWS credential" {
  # The docs target publishes to Pages or Cloudflare and ansible talks to hosts over SSH.
  # Skipping either for a missing role would be an honest skip that is simply wrong.
  for target in github-pages ansible cloudflare-workers; do
    IS_FORK=false TARGET="$target" ROLE_TO_ASSUME= run bash "${SCRIPTS}/preflight.sh"
    [ "$status" -eq 0 ]
    [ "$(output_value skip)" = "false" ]
  done
}

@test "a terragrunt run on a non-AWS estate is not skipped for want of a credential it never uses" {
  # The failure: terragrunt was treated as an AWS target, so an estate whose state lives in
  # Azure storage (the case terragrunt-stack-env carries ARM_ACCESS_KEY for) got
  # "no AWS credential is available for target: terragrunt" and every terragrunt step in
  # action.yml, all of them gated on this skip, became a no-op. Terragrunt takes its
  # credentials from its own backend and provider configuration, so this run must proceed.
  IS_FORK=false TARGET=terragrunt ROLE_TO_ASSUME= run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
  [ -z "$(output_value skip-reason)" ]
  refute grep -q "no AWS credential" "$GITHUB_STEP_SUMMARY"
}

@test "a role makes it proceed" {
  IS_FORK=false ROLE_TO_ASSUME=arn:aws:iam::1:role/x run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "ambient credentials from an earlier step are accepted" {
  IS_FORK=false ROLE_TO_ASSUME= AWS_ACCESS_KEY_ID=AKIAEXAMPLE run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "a fork preview can be opted into" {
  IS_FORK=true ALLOW_FORK_PREVIEW=true ROLE_TO_ASSUME=arn:aws:iam::1:role/x \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "an azure-functions-zip run with no Azure credential skips with a reason" {
  # HOME is redirected at a scratch directory on purpose: the ambient check below looks for
  # ~/.azure, and a developer machine that has ever run `az login` has one. Without this the
  # test passes locally for the wrong reason and fails on a runner.
  HOME="$WORK" IS_FORK=false TARGET=azure-functions-zip AZURE_CLIENT_ID= AZURE_SUBSCRIPTION_ID= \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"no Azure credential"* ]]
  [[ "$(output_value skip-reason)" == *"azure-client-id"* ]]
}

@test "an azure-apim-policy run with no Azure credential skips with a reason" {
  HOME="$WORK" IS_FORK=false TARGET=azure-apim-policy AZURE_CLIENT_ID= AZURE_SUBSCRIPTION_ID= \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "true" ]
  [[ "$(output_value skip-reason)" == *"no Azure credential"* ]]
  [[ "$(output_value skip-reason)" == *"azure-apim-policy"* ]]
}

@test "an azure-apim-policy run with a client id proceeds" {
  HOME="$WORK" IS_FORK=false TARGET=azure-apim-policy \
    AZURE_CLIENT_ID=11111111-2222-3333-4444-555555555555 \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "an azure-functions-zip run with a client id proceeds" {
  HOME="$WORK" IS_FORK=false TARGET=azure-functions-zip \
    AZURE_CLIENT_ID=11111111-2222-3333-4444-555555555555 \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "an azure session an earlier step created is accepted" {
  # The ambient case for Azure is a directory, not a variable: `az login` writes ~/.azure.
  # Without this branch, running `azure/login` yourself and leaving azure-client-id empty —
  # which the input documents as supported — would skip the deploy for no visible reason.
  mkdir -p "${WORK}/.azure"
  HOME="$WORK" IS_FORK=false TARGET=azure-functions-zip AZURE_CLIENT_ID= AZURE_SUBSCRIPTION_ID= \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
}

@test "an azure-functions-zip run is not skipped for want of an AWS credential" {
  HOME="$WORK" IS_FORK=false TARGET=azure-functions-zip ROLE_TO_ASSUME= \
    AZURE_CLIENT_ID=11111111-2222-3333-4444-555555555555 \
    run bash "${SCRIPTS}/preflight.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value skip)" = "false" ]
  refute grep -q "no AWS credential" "$GITHUB_STEP_SUMMARY"
}
