#!/usr/bin/env bash
# The cloudflare-docs target: publish a built MkDocs site to Workers Static Assets.
#
# The site Worker this publishes has NO route and NO workers.dev URL. It is reachable only
# through the docs router's service binding on `cloudflare-docs-host`, which is what makes the
# Access application on that hostname a gate on the *user* rather than something the router
# holds a token past (ADR-0005). So two things differ from `cloudflare-workers`, and both fall
# out of that:
#
#   * The published URL cannot be parsed from Wrangler's output, because Wrangler has no URL
#     to print — there is no route and no subdomain. It is composed from the host and path the
#     router dispatches on, which is the address a human actually visits.
#
#   * A pull request publishes NOTHING. `versions upload --preview-alias` needs a workers.dev
#     subdomain to serve the preview on, and `workers_dev = false` is the invariant the whole
#     design rests on. That leaves no preview destination — the same position `github-pages`
#     is in, where one site means publishing to it is publishing. The build is the check.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
SITE_DIR="${SITE_DIR:-site}"
CONFIG="${CONFIG:-}"
WORKER_NAME="${WORKER_NAME:-}"
CF_ENV="${CF_ENV:-}"
DOCS_HOST="${DOCS_HOST:-}"
DOCS_PATH="${DOCS_PATH:-}"
WRANGLER_VERSION="${WRANGLER_VERSION:-}"
# Overridable so bats can put a recorder in front of it; production always uses npx with a
# pinned version rather than whatever `wrangler` happens to be on PATH.
WRANGLER_BIN="${WRANGLER_BIN:-}"

# Refusing an empty asset directory is the same guard the s3-cloudfront target has, for the
# same reason: publishing nothing over a site that is currently serving SUCCEEDS. A --strict
# build that produced no files is the shape this catches.
[[ -d "$SITE_DIR" ]] || tremvok::fail "pages-site-dir '${SITE_DIR}' is not a directory. Nothing was built."
if [[ -z "$(find "$SITE_DIR" -type f -print -quit 2>/dev/null)" ]]; then
  tremvok::fail "pages-site-dir '${SITE_DIR}' has no files in it. Refusing to publish an empty site over one that is currently serving."
fi

url=""
if [[ -n "$DOCS_HOST" ]]; then
  # The trailing slash is load-bearing, not cosmetic: `/tremvok` and `/tremvok/` are different
  # requests to an assets router, and the router redirects the first to the second so that the
  # relative links in the page that comes back resolve correctly.
  if [[ -n "$DOCS_PATH" ]]; then
    url="https://${DOCS_HOST}/${DOCS_PATH#/}"
    url="${url%/}/"
  else
    url="https://${DOCS_HOST}/"
  fi
fi

if tremvok::is_true "$DRY_RUN" || [[ "$MODE" != "deploy" ]]; then
  tremvok::notice "cloudflare-docs: built and checked, published nothing (mode=${MODE}, dry-run=${DRY_RUN}). These Workers have no preview destination: workers_dev is false by design."
  tremvok::set_output deployed false
  tremvok::set_output url "$url"
  exit 0
fi

# Credentials are required HERE, below the early return above, and not at the top of the
# file. Nothing before this point touches Cloudflare: a pull request or a dry run builds the
# site, checks it is not empty, reports "published nothing" and exits 0. Requiring a token to
# reach that was a hard failure for anyone whose pull requests do not carry secrets, which is
# every Dependabot pull request — `CLOUDFLARE_API_TOKEN is required — cloudflare-api-token`,
# on a bump that could not have affected the docs. A real publish still refuses without them.
tremvok::require CLOUDFLARE_API_TOKEN "cloudflare-api-token"
tremvok::require CLOUDFLARE_ACCOUNT_ID "cloudflare-account-id"

if [[ -z "$WRANGLER_BIN" ]]; then
  tremvok::require WRANGLER_VERSION "cloudflare-wrangler-version"
  WRANGLER_BIN="npx --yes wrangler@${WRANGLER_VERSION}"
fi

args=(deploy)
[[ -n "$CONFIG" ]] && args+=(--config "$CONFIG")
[[ -n "$WORKER_NAME" ]] && args+=(--name "$WORKER_NAME")
[[ -n "$CF_ENV" ]] && args+=(--env "$CF_ENV")
tremvok::log "publishing ${SITE_DIR} as a Worker with static assets"
# shellcheck disable=SC2086
$WRANGLER_BIN "${args[@]}"

tremvok::set_output deployed true
tremvok::set_output url "$url"
if [[ -n "$url" ]]; then
  tremvok::summary "Docs published to ${url}"
  tremvok::notice "docs published to ${url}"
else
  # No host configured means nothing can say where this went. Worth a warning rather than
  # silence: the notification and the deployment record both carry an empty URL.
  tremvok::warn "cloudflare-docs: published, but cloudflare-docs-host is empty so no URL can be reported."
fi
