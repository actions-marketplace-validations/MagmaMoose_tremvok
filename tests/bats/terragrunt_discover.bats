#!/usr/bin/env bats

load helper

setup() {
  setup_common
  cd "$WORK"
  mkdir -p terraform/aws/prod/eu-west-1/api terraform/aws/prod/eu-west-1/artifacts \
           terraform/aws/modules/tremvok-api terraform/oci/prod/network
  touch terraform/terragrunt.hcl terraform/root.hcl
  touch terraform/aws/prod/eu-west-1/api/terragrunt.hcl
  touch terraform/aws/prod/eu-west-1/artifacts/terragrunt.hcl
  touch terraform/aws/modules/tremvok-api/terragrunt.hcl
  touch terraform/oci/prod/network/terragrunt.hcl
}

@test "all finds every leaf and never the shared root" {
  run bash "${SCRIPTS}/terragrunt-discover.sh" all
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  [[ "$output" == *"terraform/oci/prod/network"* ]]
  # `terraform/` itself holds the shared include, not a stack.
  refute grep -qx "terraform" <<<"$output"
}

@test "modules are excluded: a module has no state of its own" {
  run bash "${SCRIPTS}/terragrunt-discover.sh" all
  [[ "$output" != *"modules/tremvok-api"* ]]
}

@test "a changed file maps to its enclosing stack" {
  printf 'terraform/aws/prod/eu-west-1/api/terragrunt.hcl\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/aws/prod/eu-west-1/api" ]
}

@test "a file nested inside a stack still finds it" {
  mkdir -p terraform/aws/prod/eu-west-1/api/files/deep
  printf 'terraform/aws/prod/eu-west-1/api/files/deep/policy.json\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/aws/prod/eu-west-1/api" ]
}

@test "a shared root.hcl above several stacks maps to all of them, instead of the zero stacks that published a false green check" {
  # The failure: a change to shared configuration walked UP looking for an enclosing stack,
  # found none, and mapped to nothing. The run then published "No Terraform stacks affected"
  # as SUCCESS and the pull request merged green with every stack under that root unplanned.
  # Every stack beneath it includes it through find_in_parent_folders, so every one changed.
  printf 'terraform/aws/root.hcl\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/artifacts"* ]]
  # Beneath a different root, so untouched by this change.
  refute grep -qx "terraform/oci/prod/network" <<<"$output"
}

@test "a shared file at ROOT_DIR itself maps to every stack, because a file every stack includes has changed every stack" {
  printf 'terraform/root.hcl\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/artifacts"* ]]
  [[ "$output" == *"terraform/oci/prod/network"* ]]
}

@test "exclusions still apply to the expanded set, so a shared root never drags a module in as a stack" {
  mkdir -p terraform/aws/shared-lib/base
  touch terraform/aws/shared-lib/base/terragrunt.hcl
  printf 'terraform/root.hcl\n' >changed.txt
  EXCLUDE_SEGMENTS='modules shared-lib' run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  refute grep -q 'modules/tremvok-api' <<<"$output"
  refute grep -q 'shared-lib' <<<"$output"
}

@test "a deleted shared file still maps to the stacks beneath it, because its directory may no longer exist to test for" {
  # No mkdir and no touch: the path is a deletion, so nothing on disk answers for it.
  printf 'terraform/aws/gone-root.hcl\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/artifacts"* ]]
}

@test "a changed module maps to the stacks in its subtree, because mapping it to nothing publishes a green check saying no stack was affected" {
  # THIS REVERSES AN EARLIER DECISION, deliberately. The previous rule was that a module maps
  # to nothing, on the argument that guessing which stacks use it from its path is how a module
  # tidy-up plans the whole estate, and that the drift run covers what is missed.
  #
  # What changed is knowing what the narrow answer actually does. Zero stacks is not reported
  # as "we did not look"; deploy-terragrunt.sh publishes SUCCESS with "No Terraform stacks
  # affected", the pull request merges green, and the merge applies nothing. A real change to
  # shared logic lands with nothing planned and nobody told, until the drift run notices, if it
  # is not already red.
  #
  # The two errors are not symmetric. Planning is read only, and an apply only applies what its
  # plan found, so a module edit that changes no stack produces an empty diff and applies
  # nothing anyway: the wide answer costs wall-clock. The narrow one costs correctness. Which
  # stacks a module reaches cannot be known without evaluating the HCL, so the choice is
  # between two guesses, and this is the one that fails loudly.
  printf 'terraform/aws/modules/tremvok-api/main.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/aws/prod/eu-west-1/api"* ]]
  # Still bounded: it answers at the first ancestor that holds stacks and never widens to the
  # whole root, so an unrelated estate under the same root is untouched.
  refute grep -q 'terraform/oci' <<<"$output"
}

@test "an unrelated changed file maps to nothing" {
  printf 'README.md\n.github/workflows/ci.yaml\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ -z "$output" ]
}

@test "a changed path outside ROOT_DIR maps to nothing even though it has no enclosing stack, because the walk-down is for shared Terraform configuration and not for every file in the repository" {
  # The shape that would break this: expanding "no enclosing stack" without checking the path
  # is inside ROOT_DIR at all, which turns a README edit into a plan of the whole estate.
  printf 'docs/setup.md\nscripts/lib/common.sh\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "several files in one stack yield it once" {
  printf 'terraform/aws/prod/eu-west-1/api/terragrunt.hcl\nterraform/aws/prod/eu-west-1/api/x.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$(wc -l <<<"$output")" -eq 1 ]
}

@test "a deleted file's stack is still found" {
  printf 'terraform/oci/prod/network/gone.tf\n' >changed.txt
  run bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$output" = "terraform/oci/prod/network" ]
}

@test "a shared file does not reach a SIBLING directory whose name it merely prefixes, because the trailing slash is what stops terraform/eu matching terraform/eurofiber" {
  mkdir -p terraform/eu/live terraform/eurofiber/live
  touch terraform/eu/live/terragrunt.hcl
  touch terraform/eurofiber/live/terragrunt.hcl
  touch terraform/eu/root.hcl
  printf 'terraform/eu/root.hcl\n' >changed.txt
  run env ROOT_DIR=terraform bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/eu/live"* ]]
  refute grep -q 'eurofiber' <<<"$output"
}

@test "a shared file above the stacks reaches them by walking up its ancestors, because a module lives in an excluded directory that no stack sits beneath" {
  mkdir -p terraform/estate/_modules/thing terraform/estate/prod
  touch terraform/estate/prod/terragrunt.hcl
  touch terraform/estate/_modules/thing/main.tf
  printf 'terraform/estate/_modules/thing/main.tf\n' >changed.txt
  run env ROOT_DIR=terraform EXCLUDE_SEGMENTS="_modules" bash "${SCRIPTS}/terragrunt-discover.sh" changed changed.txt
  [ "$status" -eq 0 ]
  # One level of dirname finds nothing here: no stack sits under _modules/thing. Zero stacks
  # would be published as "No Terraform stacks affected" on a green check.
  [[ "$output" == *"terraform/estate/prod"* ]]
}
