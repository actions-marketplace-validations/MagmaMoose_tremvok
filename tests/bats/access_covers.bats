#!/usr/bin/env bats
#
# The gate that must not report the wrong thing.
#
# `.claude/COMMON_MISTAKES.md` carries this class twice already: a required check that never
# reports, and an unreadable review list read as "nobody approved". Here the shape is a 403
# from a token without Access:Apps:Read, whose JSON looks very like an account with no Access
# applications. If those two collapse into one answer, `require-access: true` publishes a
# private site to the open internet and says it checked.

load helper

setup() {
  setup_common
  cd "$WORK"

  export REQUIRE_ACCESS=true
  export ACCESS_HOST=docs.magmamoose.com
  export ACCESS_PATH=tremvok
  export CLOUDFLARE_API_TOKEN=cf-token-value
  export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef
  export CF_API=https://api.cloudflare.invalid/client/v4
}

# curl_returns <http-status> <body-json>
curl_returns() {
  local code="$1" body="$2"
  cat >"${STUB_BIN}/curl" <<STUBEOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${STUB_LOG}"
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  prev="\$a"
done
[ -n "\$out" ] && cat >"\$out" <<'BODYEOF'
${body}
BODYEOF
printf '%s' '${code}'
STUBEOF
  chmod +x "${STUB_BIN}/curl"
}

run_gate() { run bash "${SCRIPTS}/access-covers.sh"; }

@test "an application on the exact path covers it" {
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com/tremvok"}]}'
  run_gate
  [ "$status" -eq 0 ]
  [ "$(output_value access-covered)" = "true" ]
}

@test "an application on the bare hostname covers every path on it" {
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com"}]}'
  run_gate
  [ "$status" -eq 0 ]
}

@test "a trailing slash on the application domain still covers" {
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com/tremvok/"}]}'
  run_gate
  [ "$status" -eq 0 ]
}

@test "a prefix that is not a path segment does NOT cover" {
  # `…/trem` must not be read as covering `…/tremvok`.
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com/trem"}]}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'no Cloudflare Access application covers'
}

@test "another repo's application does not cover this one" {
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com/noctyr"}]}'
  run_gate
  [ "$status" -ne 0 ]
}

@test "no applications at all is a refusal that names what exists" {
  curl_returns 200 '{"success":true,"result":[]}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'Existing applications: none'
}

@test "the refusal lists the applications that DO exist" {
  curl_returns 200 '{"success":true,"result":[{"domain":"other.magmamoose.com"}]}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'other.magmamoose.com'
}

@test "a 403 is unreadable, NOT 'no applications exist'" {
  curl_returns 403 '{"success":false,"errors":[{"code":9109,"message":"Unauthorized"}]}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq "Access: Apps"
  printf '%s\n' "$output" | grep -Fq 'could not read its input'
  refute grep -Fq 'no Cloudflare Access application covers' <<<"$output"
}

@test "an unreachable API refuses rather than assuming protection" {
  curl_returns 000 ''
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'could not reach the Cloudflare API'
}

@test "a 200 carrying unreadable JSON refuses" {
  curl_returns 200 'not json at all'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'not readable JSON'
}

@test "success:false in a 200 body refuses" {
  curl_returns 200 '{"success":false,"result":null}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'not readable JSON'
}

@test "require-access off does not call Cloudflare at all" {
  export REQUIRE_ACCESS=false
  curl_returns 200 '{"success":true,"result":[]}'
  run_gate
  [ "$status" -eq 0 ]
  [ "$(output_value access-covered)" = "skipped" ]
  refute grep -Fq 'curl' "$STUB_LOG"
}

@test "a missing account id is named rather than sent as empty" {
  unset CLOUDFLARE_ACCOUNT_ID
  curl_returns 200 '{"success":true,"result":[]}'
  run_gate
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'cloudflare-account-id'
}

@test "with no path scope, the host alone is the target" {
  export ACCESS_PATH=""
  curl_returns 200 '{"success":true,"result":[{"domain":"docs.magmamoose.com"}]}'
  run_gate
  [ "$status" -eq 0 ]
}
