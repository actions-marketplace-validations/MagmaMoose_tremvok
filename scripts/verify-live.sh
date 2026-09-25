#!/usr/bin/env bash
# Prove the thing that was uploaded is the thing now being served.
#
#   "A deploy that uploads but does not bind is the failure worth catching: the old version
#    keeps serving and everything looks green."   — dunmir/deploy-frontend.yml
#
# That is the entire justification for this file. A successful `aws s3 sync` means the objects
# are in the bucket; it says nothing about whether CloudFront serves them, whether the
# invalidation landed, or whether the distribution is even pointed at that bucket. A successful
# `update-function-code` says nothing about whether the alias moved.
#
# Two checks, both opt-in:
#   verify-url     the URL answers with the expected status, with retries for propagation
#   verify-header  a named response header is present (and optionally matches a pattern)
#
# `verify-method` exists because a GET cannot verify a large class of endpoints at all. A
# webhook receiver binds POST and nothing else, so a GET reaches no function and the platform
# answers 404 — which is also what a package containing no functions returns, making the check
# unable to tell a working deploy from a broken one. Asserting `POST -> 401` instead proves the
# function is bound AND that its signature check runs, which is the thing worth knowing.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VERIFY_URL="${VERIFY_URL:-}"
VERIFY_HEADER="${VERIFY_HEADER:-}"
VERIFY_HEADER_MATCH="${VERIFY_HEADER_MATCH:-}"
EXPECT_STATUS="${EXPECT_STATUS:-200}"
VERIFY_METHOD="${VERIFY_METHOD:-GET}"
ATTEMPTS="${ATTEMPTS:-6}"
DELAY="${DELAY:-10}"
TIMEOUT="${TIMEOUT:-15}"

if [[ -z "$VERIFY_URL" ]]; then
  tremvok::log "no verify-url set; skipping post-deploy verification"
  tremvok::set_output verified "false"
  tremvok::set_output verify-skipped "true"
  exit 0
fi

case "$VERIFY_URL" in
  https://*|http://*) ;; # DevSkim: ignore DS137138 - case pattern, not an http call
  *) tremvok::fail "verify-url must be an http(s) URL, got '${VERIFY_URL}'" ;;
esac

# Upper-cased rather than validated against a list: PATCH, PURGE and the WebDAV verbs are all
# legitimate things to probe, and an allowlist would refuse them for no gain. A typo fails
# loudly at the first request instead, with the status in the log. `tr` because bash 3.2 has no
# case-modifying parameter expansion (`${1^^}`) and the macOS runners still ship it. Written
# with the positional form for the same reason common.sh writes `${1,,}`: the check in
# tests/bats/portability.bats greps for the construct and cannot tell code from a comment
# about it, and a NAMED variable in that shape trips it.
VERIFY_METHOD="$(printf '%s' "$VERIFY_METHOD" | tr '[:lower:]' '[:upper:]')"

headers_file="$(mktemp)"
trap 'rm -f "$headers_file"' EXIT

# check_once is invoked by name via tremvok::retry on the line below
# shellcheck disable=SC2329
check_once() {
  local status
  # -D dumps the response headers so one request answers both questions. `--fail` is
  # deliberately NOT used: a 403 is a result to report, not a curl error to hide.
  # `--post301 --post302 --post303` keep the METHOD across a redirect. Without them curl
  # silently downgrades a redirected POST to a GET, so an `http -> https` or a trailing-slash
  # redirect would turn "POST returns 401" into "GET returns 404" and report the assertion as
  # failed for a reason that has nothing to do with the deploy. They affect POST only, so a
  # plain GET check behaves exactly as it did before.
  status="$(curl --silent --show-error --location --post301 --post302 --post303 \
    --request "$VERIFY_METHOD" --max-time "$TIMEOUT" \
    --dump-header "$headers_file" --output /dev/null \
    --write-out '%{http_code}' "$VERIFY_URL" 2>/dev/null || printf '000')"

  if [[ "$status" != "$EXPECT_STATUS" ]]; then
    tremvok::log "  ${VERIFY_METHOD} ${VERIFY_URL} -> ${status} (want ${EXPECT_STATUS})"
    return 1
  fi

  if [[ -n "$VERIFY_HEADER" ]]; then
    local line
    # Header names are case-insensitive on the wire, and HTTP/2 lower-cases them, so a
    # case-sensitive grep here would pass on HTTP/2 and fail on HTTP/1.1 for the same server.
    line="$(grep -i "^${VERIFY_HEADER}:" "$headers_file" | tail -1 || true)"
    if [[ -z "$line" ]]; then
      tremvok::log "  ${VERIFY_URL} -> ${status}, but the '${VERIFY_HEADER}' header is absent"
      return 1
    fi
    if [[ -n "$VERIFY_HEADER_MATCH" ]] && ! grep -qiE "$VERIFY_HEADER_MATCH" <<<"$line"; then
      tremvok::log "  '${VERIFY_HEADER}' is present but does not match /${VERIFY_HEADER_MATCH}/"
      return 1
    fi
  fi
  return 0
}

tremvok::log "verifying ${VERIFY_METHOD} ${VERIFY_URL} (expect ${EXPECT_STATUS}${VERIFY_HEADER:+, header ${VERIFY_HEADER}})"
if tremvok::retry "$ATTEMPTS" "$DELAY" check_once; then
  tremvok::log "verified"
  tremvok::set_output verified "true"
  tremvok::set_output verify-skipped "false"
  exit 0
fi

tremvok::set_output verified "false"
tremvok::set_output verify-skipped "false"
# Single quotes inside ${VERIFY_HEADER:+...} are literal cosmetic chars, not shell quoting
# shellcheck disable=SC2016
tremvok::fail "post-deploy verification failed after ${ATTEMPTS} attempts: ${VERIFY_METHOD} ${VERIFY_URL} never answered ${EXPECT_STATUS}${VERIFY_HEADER:+ with a '${VERIFY_HEADER}' header}. The upload may have succeeded while the old version is still being served."
