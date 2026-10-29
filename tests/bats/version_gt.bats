#!/usr/bin/env bats
#
# tremvok::version_gt, the "is this tag newer?" that keeps a deploy from moving an overlay
# backwards. It follows SemVer precedence where both tags are versions, because the one
# comparison a release-candidate promotion makes is the one `sort -V` gets backwards: it puts
# 1.2.3 before 1.2.3-rc.1, so an overlay running a candidate refused the candidate's own
# stable release as a downgrade.

load helper

setup() {
  setup_common
  # shellcheck source=scripts/lib/common.sh
  source "${SCRIPTS}/lib/common.sh"
}

gt() { tremvok::version_gt "$1" "$2"; }

@test "a release is newer than its own prereleases, and they are older than it" {
  gt v1.2.3 v1.2.3-rc.1
  refute gt v1.2.3-rc.1 v1.2.3
}

@test "prerelease numbers compare numerically" {
  gt v1.2.3-rc.10 v1.2.3-rc.9
  refute gt v1.2.3-rc.9 v1.2.3-rc.10
}

@test "the version core decides before any prerelease" {
  gt v1.2.4-rc.1 v1.2.3
  refute gt v1.2.3 v1.2.4-rc.1
  gt v1.10.0 v1.9.9
}

@test "prerelease identifiers follow SemVer: shorter is older, numeric below alphanumeric" {
  gt 1.2.3-alpha.1 1.2.3-alpha
  refute gt 1.2.3-alpha 1.2.3-alpha.1
  gt 1.2.3-alpha 1.2.3-1
  refute gt 1.2.3-1 1.2.3-alpha
  gt 1.2.3-rc.1 1.2.3-beta.2
}

@test "a tag is not newer than itself" {
  refute gt v1.2.3 v1.2.3
  refute gt v1.2.3-rc.1 v1.2.3-rc.1
}

@test "a prefix carries through, and leading zeros do not read as octal" {
  gt core-v2.0.0 core-v1.9.0
  gt v1.2.08 v1.2.7
}

@test "tags that are not versions fall back to version sort" {
  gt test-a1b2c3d-1760000600 test-a1b2c3d-1760000000
  gt 7.4 7.3
  refute gt 7.3 7.4
}
