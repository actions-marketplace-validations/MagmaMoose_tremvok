#!/usr/bin/env bats

load helper

setup() {
  setup_common
  export SITE="${WORK}/dist"
  mkdir -p "$SITE"
  printf '<html></html>' >"${SITE}/index.html"
  printf 'body{}' >"${SITE}/app.abc123.css"
  stub aws 0 ''
}

@test "an empty artifact directory is refused before anything is synced" {
  # The failure this exists for: a build that quietly produced nothing, followed by
  # `aws s3 sync --delete`, empties the live site and exits 0 while doing it.
  rm -rf "${SITE:?}"/*
  BUCKET=site ARTIFACT_PATH="$SITE" run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains no files"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "a directory holding only empty subdirectories is also refused" {
  rm -rf "${SITE:?}"/*
  mkdir -p "${SITE}/assets/img"
  BUCKET=site ARTIFACT_PATH="$SITE" run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -ne 0 ]
}

@test "a missing artifact directory is refused" {
  BUCKET=site ARTIFACT_PATH="${WORK}/nope" run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "a deploy syncs to the bucket root with --delete" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=deploy run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  grep -q -- "s3 sync ${SITE} s3://site --delete" "$STUB_LOG"
}

@test "assets and documents get different cache headers, documents last" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=deploy run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  grep -q 'immutable' "$STUB_LOG"
  grep -q 'must-revalidate' "$STUB_LOG"
  # Documents reference assets, so the asset pass must not be the one that runs second.
  [ "$(grep -n 'immutable' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt \
    "$(grep -n 'must-revalidate' "$STUB_LOG" | head -1 | cut -d: -f1)" ]
}

@test "a preview lands under its own prefix and cannot touch production objects" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=preview PREVIEW_ALIAS=pr-42 \
    run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  grep -q "s3://site/previews/pr-42" "$STUB_LOG"
  refute grep -qE "s3 sync [^ ]+ s3://site --" "$STUB_LOG"
}

@test "a preview without an alias is refused" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=preview run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -ne 0 ]
}

@test "the invalidation is scoped to the preview prefix" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=preview PREVIEW_ALIAS=pr-42 DISTRIBUTION_ID=E123 \
    run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  grep -q -- "cloudfront create-invalidation --distribution-id E123 --paths /previews/pr-42/\*" "$STUB_LOG"
}

@test "no distribution means a warning, not a silent stale site" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=deploy run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [[ "$output" == *"::warning::"*"keep serving the old ones"* ]]
}

@test "delete-orphans false leaves existing objects alone" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=deploy DELETE_ORPHANS=false \
    run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  refute grep -q -- "--delete" "$STUB_LOG"
}

@test "the reported URL points at the preview, not the apex" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=preview PREVIEW_ALIAS=pr-9 \
    SITE_URL=https://magmamoose.com run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$(output_value url)" = "https://magmamoose.com/previews/pr-9/" ]
}

@test "a dry run changes nothing" {
  BUCKET=site ARTIFACT_PATH="$SITE" MODE=deploy DISTRIBUTION_ID=E1 DRY_RUN=true \
    run bash "${SCRIPTS}/deploy-s3-cloudfront.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ "$output" == *"DRY RUN"* ]]
}
