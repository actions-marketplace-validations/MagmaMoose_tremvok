#!/usr/bin/env bats

load helper

setup() {
  setup_common
  export ZIP="${WORK}/package.zip"
  printf 'PK\x03\x04not-really-a-zip-but-bytes-are-bytes' >"$ZIP"
  export ZIP_B64 ZIP_HEX
  ZIP_B64="$(openssl dgst -sha256 -binary "$ZIP" | openssl base64 -A)"
  ZIP_HEX="$(openssl dgst -sha256 -hex "$ZIP" | awk '{print $NF}')"

  # An `aws` that answers per subcommand. HEAD_RESULT and CODE_SHA let a test choose the two
  # interesting variables: whether the key already exists, and what Lambda says it installed.
  stub_script aws <<'STUBEOF'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"${STUB_LOG}"
case "$1 $2" in
  "s3api head-object")
    [ -n "${HEAD_RESULT:-}" ] || exit 1
    printf '%s' "$HEAD_RESULT"; exit 0 ;;
  "s3api put-object") printf '{}' ; exit 0 ;;
  "lambda update-function-code")
    printf '{"Version":"%s","CodeSha256":"%s"}' "${PUBLISHED_VERSION:-7}" "${CODE_SHA:-$ZIP_B64}"; exit 0 ;;
  "lambda wait") exit 0 ;;
  "lambda update-alias") [ "${ALIAS_EXISTS:-true}" = "true" ] && exit 0 || exit 1 ;;
  "lambda create-alias") exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
}

@test "a deploy uploads, publishes and moves the alias" {
  FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    MODE=deploy run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  grep -q "s3api put-object --bucket artifacts --key releases/1.2.3.zip" "$STUB_LOG"
  grep -q "lambda update-function-code" "$STUB_LOG"
  grep -q "lambda update-alias --function-name fn --name live --function-version 7" "$STUB_LOG"
  [ "$(output_value version-id)" = "7" ]
  [ "$(output_value alias-moved)" = "true" ]
}

@test "a preview publishes a version but leaves production alone" {
  # The whole point of a preview for a Lambda: prove the package builds, uploads and passes
  # Lambda's own validation, without changing what production serves.
  FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    MODE=preview run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  refute grep -q "alias" "$STUB_LOG"
  [ "$(output_value alias-moved)" = "false" ]
}

@test "an existing key with different bytes is a hard failure, never an overwrite" {
  # Overwriting a published key would change the code behind a version somebody already
  # reviewed and released. There is no flag to allow it.
  HEAD_RESULT="0000000000000000000000000000000000000000000000000000000000000000" \
    FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"immutable"* ]]
  refute grep -q "put-object" "$STUB_LOG"
}

@test "an existing key with identical bytes is an idempotent re-run" {
  HEAD_RESULT="$ZIP_HEX" \
    FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  refute grep -q "put-object" "$STUB_LOG"
  grep -q "update-function-code" "$STUB_LOG"
}

@test "a digest mismatch after publishing fails the deploy" {
  # "The API accepted my request" is not "the function runs my code".
  CODE_SHA="c29tZXRoaW5nLWVsc2U=" \
    FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not running the package this run built"* ]]
}

@test "a missing alias is created rather than failing" {
  ALIAS_EXISTS=false \
    FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    MODE=deploy run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  grep -q "lambda create-alias" "$STUB_LOG"
}

@test "an empty artifact is refused" {
  : >"${WORK}/empty.zip"
  FUNCTION_NAME=fn ARTIFACT_PATH="${WORK}/empty.zip" ARTIFACT_BUCKET=artifacts \
    VERSION_LABEL=1.0.0 run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -ne 0 ]
}

@test "the version label defaults to the short commit" {
  GITHUB_SHA=abcdef1234567890 FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts \
    run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  [ "$(output_value artifact-key)" = "releases/abcdef123456.zip" ]
}

@test "a dry run touches nothing" {
  FUNCTION_NAME=fn ARTIFACT_PATH="$ZIP" ARTIFACT_BUCKET=artifacts VERSION_LABEL=1.2.3 \
    DRY_RUN=true run bash "${SCRIPTS}/deploy-lambda-zip.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}
