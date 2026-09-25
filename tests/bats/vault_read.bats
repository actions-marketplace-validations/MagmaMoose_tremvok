#!/usr/bin/env bats
#
# The value read here becomes an SSH private key on disk. Two things therefore matter more
# than the happy path: a failure must fail loudly rather than return empty (an empty key
# skips the masking block and surfaces as an SSH auth error a long way from the cause), and
# nothing may print the secret or the response body, because a partial failure body can
# contain it.

load helper

setup() {
  setup_common
  cd "$WORK"
  export VAULT_ADDR="https://vault.example.invalid:8200"
  export VAULT_TOKEN="s.testtoken"

  # curl recorder. Writes the canned body to whatever -o names and prints the status, which
  # is exactly the shape the script consumes (`-o file -w '%{http_code}'`).
  stub_script curl <<'STUBEOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${STUB_LOG}"
dest=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && dest="$a"
  # Log config file contents so header assertions still work after the token moved off argv.
  [ "$prev" = "-K" ] && cat "$a" >>"${STUB_LOG}"
  prev="$a"
done
# Two lines, not `${VAULT_BODY:-{...}}`: a brace inside the default closes the parameter
# expansion at the FIRST `}`, so the rest leaks out as literal text and every override
# arrives as invalid JSON. Same trap as validate-inputs.sh.
body="${VAULT_BODY:-}"
[ -n "$body" ] || body='{"data":{"data":{"ssh_private_key":"KEYMATERIAL"}}}'
[ -n "$dest" ] && printf '%s' "$body" >"$dest"
printf '%s' "${VAULT_STATUS:-200}"
STUBEOF
}

@test "a kv v2 secret is read from .data.data" {
  run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  [ "$status" -eq 0 ]
  [ "$output" = "KEYMATERIAL" ]
}

@test "a kv v1 secret is read from .data, without the caller declaring the engine" {
  VAULT_BODY='{"data":{"ssh_private_key":"V1KEY"}}' \
    run bash "${SCRIPTS}/vault-read.sh" 'secret/team/app#ssh_private_key'
  [ "$status" -eq 0 ]
  [ "$output" = "V1KEY" ]
}

@test "the request goes to the reference's path, with the token as a header" {
  run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  grep -q 'https://vault.example.invalid:8200/v1/secret/data/team/app' "$STUB_LOG"
  grep -q 'X-Vault-Token: s.testtoken' "$STUB_LOG"
}

@test "a leading slash on the path does not double the one in the url" {
  # `//v1//secret/...` is a 404 for a secret that is plainly there, which is a confusing
  # five minutes.
  run bash "${SCRIPTS}/vault-read.sh" '/secret/data/team/app#ssh_private_key'
  grep -q '/v1/secret/data/team/app' "$STUB_LOG"
  refute grep -q '/v1//' "$STUB_LOG"
}

@test "a namespace is sent only when one is set" {
  run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  refute grep -q 'X-Vault-Namespace' "$STUB_LOG"
  : >"$STUB_LOG"
  VAULT_NAMESPACE=admin/team run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  grep -q 'X-Vault-Namespace: admin/team' "$STUB_LOG"
}

@test "a missing field fails, and names the fields that are there" {
  VAULT_BODY='{"data":{"data":{"other_field":"x","third":"y"}}}' \
    run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no field 'ssh_private_key'"* ]]
  [[ "$output" == *"other_field"* ]]
}

@test "a missing field never prints the values of the fields that are there" {
  VAULT_BODY='{"data":{"data":{"other_field":"SUPERSECRETVALUE"}}}' \
    run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERSECRETVALUE"* ]]
}

@test "a null field is a failure, not the four characters null" {
  # `// empty` rather than `// null`: writing "null" into a private key file is a failure
  # that looks like a successful read.
  VAULT_BODY='{"data":{"data":{"ssh_private_key":null}}}' \
    run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#ssh_private_key'
  [ "$status" -ne 0 ]
  [[ "$output" != *"null"* || "$output" == *"no field"* ]]
}

@test "403 says the policy is wrong, not that the secret is missing" {
  VAULT_STATUS=403 run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#k'
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy"* ]]
}

@test "404 points at the kv v2 data segment, which is the usual cause" {
  VAULT_STATUS=404 run bash "${SCRIPTS}/vault-read.sh" 'secret/team/app#k'
  [ "$status" -ne 0 ]
  [[ "$output" == *"/data/"* ]]
}

@test "an unreachable Vault says so, rather than reporting an empty secret" {
  VAULT_STATUS=000 run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#k'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot reach Vault"* ]]
}

@test "a reference with no field is refused before any request is made" {
  run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app'
  [ "$status" -ne 0 ]
  [[ "$output" == *"<path>#<field>"* ]]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "a missing addr or token is refused before any request is made" {
  VAULT_ADDR= run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#k'
  [ "$status" -ne 0 ]
  VAULT_TOKEN= run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#k'
  [ "$status" -ne 0 ]
  refute grep -q '^curl' "$STUB_LOG"
}

@test "the response body is never echoed, whatever the status" {
  VAULT_STATUS=500 VAULT_BODY='{"errors":["token SUPERSECRETVALUE is bad"]}' \
    run bash "${SCRIPTS}/vault-read.sh" 'secret/data/team/app#k'
  [ "$status" -ne 0 ]
  [[ "$output" != *"SUPERSECRETVALUE"* ]]
}
