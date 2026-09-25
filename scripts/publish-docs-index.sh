#!/usr/bin/env bash
# Publish this repository's docs corpus to the shared R2 bucket at `index/<repo>.json`.
#
# Per ADR-0005 this is the whole synchronisation mechanism for the fleet's documentation
# corpus: fan-in happens at WRITE time. The read side (the MCP Workers) lists this bucket;
# it never calls the GitHub API and never calls other MCP servers. So the index landing
# here is not a nice-to-have after a successful deploy — it is the deploy, for every
# consumer that is an agent rather than a person.
#
# That is why this is NOT failure-isolated, unlike the notification sinks. A run that
# deployed the site and silently failed to publish the corpus would be green while every
# agent-facing surface served the previous commit's documentation, with nothing to notice
# it. The webhook rule ("a deploy that succeeded never fails because a webhook did") is
# about sinks that observe the deploy. This one is part of it.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

INDEX_FILE="${INDEX_FILE:-}"
BUCKET="${BUCKET:-}"
REPO="${REPO:-}"
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
WRANGLER_VERSION="${WRANGLER_VERSION:-}"
# Overridable so bats can put a recorder in front of it; production always uses npx with a
# pinned version rather than whatever `wrangler` happens to be on PATH.
WRANGLER_BIN="${WRANGLER_BIN:-}"

# A pull request must not overwrite the shared corpus: there is one bucket and one key per
# repository, so publishing from a preview would make every agent read an unmerged branch.
# Same reasoning as `cloudflare-docs` publishing no site on a preview: the corpus has no preview
# destination either.
if tremvok::is_true "$DRY_RUN" || [[ "$MODE" != "deploy" ]]; then
  tremvok::notice "docs index: not published (mode=${MODE}, dry-run=${DRY_RUN}). The shared corpus is written only by a deploy."
  tremvok::set_output index-published false
  exit 0
fi

tremvok::require INDEX_FILE "the generated corpus"
tremvok::require BUCKET "cloudflare-docs-index-bucket"
tremvok::require REPO "the repository name"
tremvok::require CLOUDFLARE_API_TOKEN "cloudflare-api-token"
tremvok::require CLOUDFLARE_ACCOUNT_ID "cloudflare-account-id"

[[ -f "$INDEX_FILE" ]] || tremvok::fail "docs index '${INDEX_FILE}' was not generated. Nothing to publish."

if [[ -z "$WRANGLER_BIN" ]]; then
  tremvok::require WRANGLER_VERSION "cloudflare-wrangler-version"
  WRANGLER_BIN="npx --yes wrangler@${WRANGLER_VERSION}"
fi

key="index/${REPO}.json"

# `--remote` is load-bearing and its absence is silent. Without it Wrangler 4 writes to the
# LOCAL miniflare simulation under .wrangler/state and exits 0 — a green step, a real file
# on disk, and nothing in the bucket. This is the same class of footgun as `aws s3 sync
# --delete` over an empty build: the command reports what it did, which is not what was
# asked for.
tremvok::log "publishing ${INDEX_FILE} -> r2://${BUCKET}/${key}"

# Deliberately word-split: WRANGLER_BIN is "npx --yes wrangler@x.y.z", several words.
# shellcheck disable=SC2086
$WRANGLER_BIN r2 object put "${BUCKET}/${key}" \
  --file "$INDEX_FILE" \
  --content-type application/json \
  --remote

tremvok::set_output index-published true
tremvok::set_output index-key "$key"
tremvok::summary "Docs corpus published to \`${BUCKET}/${key}\`"
tremvok::notice "docs corpus published to ${BUCKET}/${key}"
