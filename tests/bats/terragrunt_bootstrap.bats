#!/usr/bin/env bats
#
# This step decides which binary applies to production. A floating version is the one input
# nobody reviews, and an unverified download is the one supply chain nobody audits — so the
# version is pinned and the checksum is mandatory, and neither can be waved through.

load helper

setup() {
  setup_common
  cd "$WORK"
  export TREMVOK_TOOL_CACHE="${WORK}/cache"
  export GITHUB_PATH="${WORK}/github-path.txt"
  : >"$GITHUB_PATH"
  export TOFU_VERSION=1.12.1 TG_VERSION=1.0.8
  export TOFU_BASE_URL="file://${WORK}/releases/tofu" TG_BASE_URL="file://${WORK}/releases/tg"
  export PLUGIN_CACHE=""
  mkdir -p releases

  # curl and unzip stubbed so the test never reaches the network. `curl -o <dest> <url>`
  # copies from a fixture directory keyed by the last path segment.
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
src="${FIXTURES}/$(basename "$url")"
[ -f "$src" ] || exit 22
cp "$src" "$dest"
STUBEOF
  stub_script unzip <<'STUBEOF'
#!/usr/bin/env bash
printf 'unzip %s\n' "$*" >>"${STUB_LOG}"
dest="."
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && dest="$a"
  prev="$a"
done
printf 'tofu-binary\n' >"${dest}/tofu"
STUBEOF

  export FIXTURES="${WORK}/fixtures"
  mkdir -p "$FIXTURES"
  printf 'tofu-zip\n' >"${FIXTURES}/tofu_${TOFU_VERSION}_linux_amd64.zip"
  printf 'tofu-zip\n' >"${FIXTURES}/tofu_${TOFU_VERSION}_darwin_arm64.zip"
  printf 'terragrunt-binary\n' >"${FIXTURES}/terragrunt_linux_amd64"
  printf 'terragrunt-binary\n' >"${FIXTURES}/terragrunt_darwin_arm64"
  write_sums
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

write_sums() {
  : >"${FIXTURES}/tofu_${TOFU_VERSION}_SHA256SUMS"
  : >"${FIXTURES}/SHA256SUMS"
  for f in "${FIXTURES}"/tofu_*_*.zip; do
    printf '%s  %s\n' "$(sha_of "$f")" "$(basename "$f")" >>"${FIXTURES}/tofu_${TOFU_VERSION}_SHA256SUMS"
  done
  for f in "${FIXTURES}"/terragrunt_*; do
    case "$f" in *SHA256SUMS) continue ;; esac
    printf '%s  %s\n' "$(sha_of "$f")" "$(basename "$f")" >>"${FIXTURES}/SHA256SUMS"
  done
}

@test "both tools are downloaded, checksum-verified and put on PATH" {
  INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -eq 0 ]
  [ -n "$(find "$TREMVOK_TOOL_CACHE" -name tofu)" ]
  [ -n "$(find "$TREMVOK_TOOL_CACHE" -name terragrunt)" ]
  grep -q "$(find "$TREMVOK_TOOL_CACHE" -type d -name 'tofu-*')" "$GITHUB_PATH"
}

@test "a checksum that does not match refuses to install the binary" {
  printf 'tampered\n' >"${FIXTURES}/terragrunt_$(uname -s | tr 'A-Z' 'a-z')_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
  INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "no published checksum is a refusal, not a shrug" {
  : >"${FIXTURES}/SHA256SUMS"
  INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no checksum published"* ]]
}

@test "the cache directory pins both versions, so a bump cannot pick up a stale binary" {
  INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ -n "$(find "$TREMVOK_TOOL_CACHE" -maxdepth 1 -type d -name "tofu-${TOFU_VERSION}_tg-${TG_VERSION}_*")" ]
  TOFU_VERSION=1.12.2 INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh" || true
  [ -n "$(find "$TREMVOK_TOOL_CACHE" -maxdepth 1 -type d -name "tofu-${TOFU_VERSION}_tg-${TG_VERSION}_*")" ]
}

@test "a second run is a cache hit and downloads nothing" {
  INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  : >"$STUB_LOG"
  INSTALL=auto run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "install: never installs nothing and does not fail" {
  INSTALL=never run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -eq 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "an unknown install mode is refused rather than treated as auto" {
  INSTALL=maybe run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -ne 0 ]
}

@test "the provider plugin cache is exported for every stack to share" {
  # Without it every stack re-downloads every provider, which is the single biggest cost in
  # a multi-stack run.
  PLUGIN_CACHE="${WORK}/plugins" INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -eq 0 ]
  grep -q "TF_PLUGIN_CACHE_DIR=${WORK}/plugins" "$GITHUB_ENV"
  [ -d "${WORK}/plugins" ]
}

@test "a leading tilde in the plugin cache is expanded without eval" {
  HOME="${WORK}/home" PLUGIN_CACHE='~/tf-plugins' INSTALL=always \
    run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -eq 0 ]
  grep -q "TF_PLUGIN_CACHE_DIR=${WORK}/home/tf-plugins" "$GITHUB_ENV"
}

@test "a missing version is refused rather than fetching whatever is latest" {
  TG_VERSION= INSTALL=always run bash "${SCRIPTS}/terragrunt-bootstrap.sh"
  [ "$status" -ne 0 ]
}
