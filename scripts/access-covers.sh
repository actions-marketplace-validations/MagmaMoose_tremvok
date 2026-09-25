#!/usr/bin/env bash
# Refuse to publish a private docs site that no Cloudflare Access application covers.
#
# This is enforcement rather than convention, which is the whole reason it exists: "the site
# is behind Access" is otherwise a belief, held by whoever set it up, checked by nobody, and
# falsified silently the day an Access application is renamed or its domain edited. The deploy
# is the one moment something can ask Cloudflare and refuse.
#
# ADR-0005 names keeping this through the Pages -> Workers Static Assets move as one of four
# traps that have already cost time. It is easy to lose precisely because the thing it checks
# moved: under Workers Static Assets the site Workers have NO public hostname at all
# (`workers_dev = false`, no routes, reachable only through the router's service binding), so
# the application to look for is the one on the ROUTER's path — `docs.magmamoose.com/<repo>`
# — not one on a per-site hostname that no longer exists.
#
# THE FAILURE MODES ARE NEVER COLLAPSED. `scripts/resolve-merged-pr.sh` learned this the hard
# way and `.claude/COMMON_MISTAKES.md` records the class: a gate that cannot read its input
# must not report the same thing as a gate that read it and found nothing. Here:
#
#   covered        exit 0
#   not covered    exit 1, naming what would have had to exist
#   unreadable     exit 1, naming WHY it could not tell — a 403 from a token without
#                  Access:Apps:Read is the likely one, and it must never read as "no
#                  applications exist", which is the same JSON shape with an empty list.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REQUIRE_ACCESS="${REQUIRE_ACCESS:-false}"
ACCESS_HOST="${ACCESS_HOST:-}"
ACCESS_PATH="${ACCESS_PATH:-}"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"

if ! tremvok::is_true "$REQUIRE_ACCESS"; then
  tremvok::log "require-access is off; not checking Access coverage."
  tremvok::set_output access-covered skipped
  exit 0
fi

tremvok::require ACCESS_HOST "the hostname the site is served on"
tremvok::require CLOUDFLARE_API_TOKEN "cloudflare-api-token"
tremvok::require CLOUDFLARE_ACCOUNT_ID "cloudflare-account-id"

# `docs.magmamoose.com/tremvok`, or just the host when no path scope was asked for.
target="$ACCESS_HOST"
if [[ -n "$ACCESS_PATH" ]]; then
  target="${ACCESS_HOST}/${ACCESS_PATH#/}"
fi
target="${target%/}"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# `--write-out` for the status rather than `--fail`: a 403 and a 200-with-empty-list are
# different answers and curl's exit code alone cannot tell them apart.
status="$(curl -sS \
  --max-time 30 \
  --retry 2 --retry-delay 2 \
  -o "$body" \
  --write-out '%{http_code}' \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  "${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?per_page=1000" || true)"

case "$status" in
  200) ;;
  000)
    tremvok::fail "require-access: could not reach the Cloudflare API to list Access applications. Refusing to publish rather than assuming the site is protected."
    ;;
  401 | 403)
    tremvok::fail "require-access: Cloudflare answered ${status} listing Access applications. The API token needs the 'Access: Apps' READ permission — the 'Edit Cloudflare Workers' template does not include it. This is NOT 'no applications exist': the gate could not read its input, so it refuses."
    ;;
  *)
    tremvok::fail "require-access: Cloudflare answered ${status} listing Access applications. Refusing to publish rather than assuming the site is protected."
    ;;
esac

if ! jq -e '.success == true and (.result | type == "array")' "$body" >/dev/null 2>&1; then
  tremvok::fail "require-access: the Access applications response was not readable JSON with a result array. Refusing to publish rather than assuming the site is protected."
fi

# Coverage: an application covers the target when its domain IS the target, is the bare
# hostname (which covers every path on it), or is a path prefix of the target on the same
# host. Compared segment-wise, so an application on `docs.magmamoose.com/trem` does not
# accidentally cover `docs.magmamoose.com/tremvok`.
covered="$(
  jq -r --arg target "$target" --arg host "$ACCESS_HOST" '
    [ .result[]?
      | (.domain // "") | sub("/$"; "")
      | select(. != "")
      | select(
          . == $target
          or . == $host
          or ($target | startswith(. + "/"))
        )
    ] | length
  ' "$body"
)"

if [[ "$covered" == "0" ]]; then
  # Every domain, so the log says what DOES exist rather than only what is missing. That is
  # the difference between a five-minute fix and an afternoon.
  known="$(jq -r '[.result[]?.domain // empty] | join(", ")' "$body")"
  tremvok::fail "require-access: no Cloudflare Access application covers '${target}'. Existing applications: ${known:-none}. Create one on '${target}' (or on '${ACCESS_HOST}' to cover every site on it) before publishing a private site."
fi

tremvok::log "require-access: ${covered} Access application(s) cover ${target}"
tremvok::set_output access-covered true
tremvok::summary "Access: \`${target}\` is covered by ${covered} application(s)"
