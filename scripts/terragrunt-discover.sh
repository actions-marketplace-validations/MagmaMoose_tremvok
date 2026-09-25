#!/usr/bin/env bash
# Map a set of changed files to the Terragrunt stacks they affect.
#
# A "stack" is a directory containing `terragrunt.hcl` that is not the repository's root
# configuration and not a shared module. Two modes:
#
#   all             every stack under ROOT_DIR (the scheduled drift run, and manual full runs)
#   changed <file>  only the stacks that own a changed path
#
# Changed-file mapping walks *up* from each changed path to the nearest enclosing stack, so
# editing a file three directories inside a stack still finds it.
#
# A path with NO enclosing stack is the other half of the map, and it used to be answered with
# silence. A shared `root.hcl` sits ABOVE every stack that includes it through
# find_in_parent_folders, so walking up from it finds nothing, and a change to it reported
# zero stacks and published the check as "No Terraform stacks affected" while every stack under
# it had in fact changed. So the walk goes the other way too: a changed path inside ROOT_DIR
# with no enclosing stack maps to every stack BENEATH its own directory. `terraform/azure/
# root.hcl` is every stack under `terraform/azure`, and a path directly in ROOT_DIR
# (`terraform/root.hcl`) is legitimately every stack there is, because that is what including
# it from everywhere means.
#
# A change under `modules/` still maps to nothing, and that falls out rather than being a
# special case: nothing beneath an excluded directory is a stack. A module has no state of its
# own, and guessing which stacks use it from a path is how a "small module tidy-up" ends up
# planning the entire estate.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ROOT_DIR="${ROOT_DIR:-terraform}"
# Directory names that hold shared code rather than a stack. Matched as a whole path segment.
EXCLUDE_SEGMENTS="${EXCLUDE_SEGMENTS:-modules _modules .terragrunt-cache .terraform}"

mode="${1:-all}"
changed_file="${2:-}"

is_excluded() {
  local path="$1" segment
  for segment in $EXCLUDE_SEGMENTS; do
    case "/${path}/" in
      */"${segment}"/*) return 0 ;;
    esac
  done
  return 1
}

# A stack is a directory with terragrunt.hcl in it. `root.hcl` / `terragrunt.hcl` at the very
# top of ROOT_DIR is the shared include, not a stack, so ROOT_DIR itself never qualifies.
is_stack() {
  local dir="$1"
  [[ "$dir" == "$ROOT_DIR" || "$dir" == "." ]] && return 1
  is_excluded "$dir" && return 1
  [[ -f "${dir}/terragrunt.hcl" ]]
}

all_stacks() {
  [[ -d "$ROOT_DIR" ]] || return 0
  # `if` rather than `is_stack && printf`: under `set -e` with `pipefail`, a loop whose LAST
  # iteration hits an excluded directory exits non-zero, which fails the whole pipeline. The
  # symptom is discovery working until somebody adds a module that sorts last.
  find "$ROOT_DIR" -name terragrunt.hcl -type f 2>/dev/null \
    | while read -r hcl; do
        dir="$(dirname "$hcl")"
        if is_stack "$dir"; then printf '%s\n' "$dir"; fi
      done \
    | sort -u
}

changed_stacks() {
  [[ -n "$changed_file" && -f "$changed_file" ]] || tremvok::fail "discover changed needs a file of changed paths"
  # Every stack, once, outside the loop: the walk-down below asks the same question of the
  # same tree for each changed path, and find is the expensive part. Assigned from a function
  # whose own last command is `sort -u`, so the assignment cannot inherit a false test.
  local every_stack
  every_stack="$(all_stacks)"
  while read -r path; do
    [[ -n "$path" ]] || continue
    dir="$(dirname "$path")"
    found=false
    # Walk up until a stack is found or the tree runs out. A deleted file's directory may no
    # longer exist, which is why this tests for terragrunt.hcl rather than for the directory.
    while [[ "$dir" != "." && "$dir" != "/" ]]; do
      if is_stack "$dir"; then
        printf '%s\n' "$dir"
        found=true
        break
      fi
      dir="$(dirname "$dir")"
    done
    # No enclosing stack, so the path is shared configuration sitting ABOVE the stacks rather
    # than inside one: a root.hcl every stack includes, or a module several of them source.
    # Walk back up its ancestors while still inside ROOT_DIR, and at each one take every stack
    # beneath it, stopping at the first ancestor that yields any.
    #
    # One level of `dirname` is NOT enough, and the case that proves it is the one this whole
    # branch exists for. A shared module lives in a directory the exclude list keeps out of the
    # stack list, `_modules` say, so no stack is ever beneath it and one level finds nothing.
    # The estate this was measured against maps a module change to three stacks by walking up
    # and to zero by not, and zero is published as "No Terraform stacks affected" on a green
    # check. Reaching a whole subtree from a module edit is not a guess to be refused; which
    # stacks a module reaches cannot be known without evaluating the HCL, and the wide answer
    # is the safe direction because the narrow one silently applies nothing.
    #
    # Stopping at the first ancestor that yields stacks is what keeps it from widening to the
    # entire root every time: `terraform/eurofiber/_modules/x` answers at `terraform/eurofiber`
    # and never asks `terraform`.
    #
    # `$every_stack` is already filtered, so exclusions apply to the expanded set for free. A
    # path directly in ROOT_DIR answers at ROOT_DIR and therefore every stack, which is correct
    # rather than a case to suppress: a file every stack includes has changed every stack.
    if [[ "$found" == false && "$path" == "$ROOT_DIR"/* ]]; then
      base="$(dirname "$path")"
      while [[ "$base" == "$ROOT_DIR"/* || "$base" == "$ROOT_DIR" ]]; do
        matched=false
        while IFS= read -r stack; do
          # The trailing slash is load-bearing: without it `terraform/eu` would match
          # `terraform/eurofiber`, and a change in one directory would plan a sibling's stacks.
          if [[ -n "$stack" && "$stack" == "$base"/* ]]; then
            printf '%s\n' "$stack"
            matched=true
          fi
        done <<<"$every_stack"
        if [[ "$matched" == true ]]; then break; fi
        [[ "$base" == */* ]] || break
        base="$(dirname "$base")"
      done
    fi
    # Same pipefail trap as above, and the reason both loops end on an `if` rather than a bare
    # test: a loop whose last iteration ends on a false test returns non-zero, and under
    # `set -e` with `pipefail` that kills discovery for every path after it.
  done <"$changed_file" | sort -u
}

case "$mode" in
  all) all_stacks ;;
  changed) changed_stacks ;;
  *) tremvok::fail "usage: terragrunt-discover.sh all|changed [changed-files-file]" ;;
esac
