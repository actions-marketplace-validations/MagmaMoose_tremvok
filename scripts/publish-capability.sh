#!/usr/bin/env bash
# Publish this repository's capability declaration to `capability/<repo>.json`, beside the
# docs corpus, in the same bucket, from the same deploy.
#
# WHY A SECOND DOCUMENT AND NOT MORE PROSE. The docs corpus cannot settle the question an
# agent asks *before* it writes a workflow: which house tool already does this, how do I
# consume it, and if none does, where do I file? Prose has to be interpreted, it does not
# carry the `uses:` ref, and — the part that matters — it cannot say NO. An agent that reads
# four pages and finds nothing cannot tell "no house tool does this" from "the tool that does
# this has not published", and those two lead to opposite actions. So capabilities are
# DECLARED, in a file at the repository root, and shipped by the deploy that already holds
# every rendered page: in sync with the repo by construction, no GitHub API at request time,
# nothing that can go stale between a merge and a cron.
#
# THREE OUTCOMES, NEVER COLLAPSED — the same rule as `access-covers.sh` and for the same
# reason:
#
#   absent      exit 0, upload nothing, say so. Most repositories are not house tools, and
#               a missing declaration is the normal case rather than a fault.
#   invalid     exit 1. A malformed declaration is read at the MCP as private-by-default and
#               reported as an unreadable document — counted, never named — which is the one
#               state that is invisible from the publishing side. A tool that vanished
#               because its JSON broke looks exactly like a tool that declared nothing.
#   valid       validated always, uploaded only by a deploy.
#
# VALIDATION RUNS ON A PULL REQUEST, THE UPLOAD DOES NOT. A declaration that only gets
# checked on `main` is checked after the merge that broke it: the PR is green and the deploy
# that finds out is someone else's. There is one key per repository, though, so a preview
# must not write — it would overwrite the shared registry with an unmerged branch, exactly as
# `publish-docs-index.sh` must not.
#
# NOT FAILURE-ISOLATED, for the same reason the docs index is not. The notification rule ("a
# deploy that succeeded never fails because a webhook did") is about sinks that observe a
# deploy. This is part of one: a run that published the site and quietly failed to publish
# the declaration is green while `find_capability` answers for the previous commit, or for
# nothing at all.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CAPABILITY_FILE="${CAPABILITY_FILE:-}"
BUCKET="${BUCKET:-}"
REPO="${REPO:-}"
COMMIT="${COMMIT:-}"
VISIBILITY="${VISIBILITY:-}"
MODE="${MODE:-deploy}"
DRY_RUN="${DRY_RUN:-false}"
WRANGLER_VERSION="${WRANGLER_VERSION:-}"
# Overridable so bats can put a recorder in front of it; production always uses npx with a
# pinned version rather than whatever `wrangler` happens to be on PATH.
WRANGLER_BIN="${WRANGLER_BIN:-}"

SCHEMA_URL="https://mcp.magmamoose.com/schema/capability.schema.json"

if [[ -z "$CAPABILITY_FILE" ]]; then
  tremvok::log "cloudflare-docs-capability-file is empty; no capability declaration is published."
  tremvok::set_output capability-declared false
  tremvok::set_output capability-published false
  exit 0
fi

tremvok::require BUCKET "cloudflare-docs-index-bucket"
tremvok::require REPO "the repository name"

key="capability/${REPO}.json"

# ABSENT IS NOT A FAULT. It is reported rather than merely skipped because the registry
# reports the same gap from the other side — `list_capabilities` names every repository that
# publishes docs and has declared nothing — and a run that says nothing here is the reason
# somebody goes looking for a bug in the MCP instead.
if [[ ! -f "$CAPABILITY_FILE" ]]; then
  tremvok::notice "no capability declaration at '${CAPABILITY_FILE}'; nothing was written to ${key}. Most repositories are not house tools, so this is the normal case."
  tremvok::summary "Capability registry: no \`${CAPABILITY_FILE}\` in this repository, so \`${key}\` was not written."
  tremvok::set_output capability-declared false
  tremvok::set_output capability-published false
  exit 0
fi

tremvok::set_output capability-declared true

# ── validate ────────────────────────────────────────────────────────────────────────────
#
# Against the capability schema (SCHEMA_URL above), checked here rather than fetched. A deploy
# that asked the MCP whether it may publish would fail every repository's deploy on the day
# the MCP is down, to check a contract that changes a few times a year. The constraints below
# ARE that schema's required fields and types; `tests/bats/capability.bats` names each one
# after the silent failure it prevents, the same way `test_the_index_meets_the_readers_contract`
# pins the corpus contract without vendoring it either.
#
# What separates an error from a warning: an error is a constraint the schema states AND the
# reader swallows without complaining — a non-string `id` is dropped from the document, so
# the capability simply stops existing. A warning is a declaration that is legal, readable,
# and probably not what was meant.
parse_error="$(jq empty "$CAPABILITY_FILE" 2>&1 >/dev/null || true)"
if [[ -n "$parse_error" ]]; then
  tremvok::fail "capability: '${CAPABILITY_FILE}' is not valid JSON, so the MCP would read it as an unreadable document — private, counted and never named. jq says: ${parse_error}"
fi

findings="$(
  jq -r --arg repo "$REPO" '
    def e($m): "E \($m)";
    def w($m): "W \($m)";
    def at($i): "capabilities[\($i)]";

    def cap_problems($i; $c):
      if ($c | type) != "object" then [ e("\(at($i)) is not an object.") ]
      else
          (if ($c.id | type) == "string" and ($c.id | test("^[a-z0-9]+(-[a-z0-9]+)*$"))
             then []
             else [ e("\(at($i)).id must be kebab-case matching ^[a-z0-9]+(-[a-z0-9]+)*$, found \($c.id | tojson). The reader drops an entry whose id is not a string and ranks the id highest of any field, so this is a capability that silently stops existing.") ]
           end)
        + (if ($c.summary | type) == "string" and ($c.summary | length) > 0
             then []
             else [ e("\(at($i)).summary must be a non-empty string, found \($c.summary | tojson). It is the one sentence a caller is shown about what they get.") ]
           end)
        + ( ["ecosystems", "inputs", "excludes"]
            | map( . as $f
                   | if ($c[$f] == null) then empty
                     elif (($c[$f] | type) == "array") and ([ $c[$f][] | select(type != "string") ] | length) == 0 then empty
                     else e("\(at($i)).\($f) must be an array of strings, found \($c[$f] | tojson). The reader keeps the strings and drops the rest without saying so.")
                     end ) )
        + (if ($c.doc == null) then []
           elif ($c.doc | type) != "string" then [ e("\(at($i)).doc must be a string, found \($c.doc | tojson).") ]
           elif ($c.doc | test("^/|://")) then [ e("\(at($i)).doc must be a repository-relative path such as docs/patch-coverage.md, found \($c.doc | tojson). It is concatenated into a docs.magmamoose.com citation, so a leading slash or a scheme produces a link that cannot resolve.") ]
           else [] end)
        + (if ($c.excludes | type) == "array" and ($c.excludes | length) > 0 then []
           else [ w("\(at($i)) (\($c.id // "?")) declares no `excludes`. A capability that only says what it covers is returned for cases it cannot serve, and the symptom is a check that passes having measured nothing.") ]
           end)
      end;

    if type != "object" then
      [ e("the declaration is not a JSON object. The MCP reads that as an unreadable document: private, counted and never named.") ]
    else
        (if .schema == 1 then [] else [ e("`schema` must be the number 1, found \(.schema | tojson).") ] end)
      + (if (.repo | type) == "string" and (.repo | length) > 0 then []
         else [ e("`repo` must be a non-empty string, found \(.repo | tojson).") ] end)
      + (if (.repo | type) == "string" and .repo != $repo
         then [ e("`repo` says \(.repo | tojson) but this repository is \"\($repo)\". The object is written to capability/\($repo).json and the reader takes the name from that key, so the declaration would speak under one name about another tool.") ]
         else [] end)
      + (if (.private | type) == "boolean" then []
         else [ e("`private` must be a JSON boolean, found \(.private | tojson). The reader fails closed on anything that is not exactly false, so a quoted \"false\" hides the tool from every public surface without reporting anything.") ] end)
      + (if (.file_issues_at == null) or ((.file_issues_at | type) == "string" and (.file_issues_at | length) > 0) then []
         else [ e("`file_issues_at` must be a non-empty string, found \(.file_issues_at | tojson).") ] end)
      + (if (.file_issues_at | type) == "string" and (.file_issues_at | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not)
         then [ w("`file_issues_at` is \(.file_issues_at | tojson), which is not an owner/repo. It is what a caller is told when nothing here covers their need, so it has to be a real, watched tracker.") ]
         else [] end)
      + (if (.action == null) or ((.action | type) == "object") then []
         else [ e("`action` must be an object, found \(.action | tojson).") ] end)
      + (if (.action | type) == "object" and (.action.uses != null) and ((.action.uses | type) != "string")
         then [ e("`action.uses` must be a string, found \(.action.uses | tojson). It is the exact value a consumer writes after `uses:`.") ]
         else [] end)
      + (if (.action | type) == "object" and (.action.kind != null) and ((.action.kind) as $kind | [ "composite-action", "reusable-workflow", "cli", "service" ] | index($kind)) == null
         then [ e("`action.kind` must be one of composite-action, reusable-workflow, cli, service. Found \(.action.kind | tojson).") ]
         else [] end)
      + (if (.capabilities | type) == "array" then
             ( [ .capabilities | to_entries[] | cap_problems(.key; .value)[] ] )
           + (if (.capabilities | length) == 0
              then [ w("`capabilities` is empty. The registry will list this tool with (0), which reads as a tool that does nothing rather than as a declaration nobody finished.") ]
              else [] end)
           + ( [ .capabilities[]? | select(type == "object") | .id | select(type == "string") ]
               | group_by(.) | map(select(length > 1) | .[0])
               | map(w("capability id \(. | tojson) is declared more than once. Only one of them can be what a caller is sent to.")) )
         else [ e("`capabilities` must be an array, found \(.capabilities | tojson). An absent or malformed list is read as a tool that declared nothing.") ]
         end)
    end
    | .[]
  ' "$CAPABILITY_FILE"
)"

errors=""
warnings=""
while IFS= read -r finding; do
  case "$finding" in
    'E '*) errors="${errors}${finding#E }"$'\n' ;;
    'W '*) warnings="${warnings}${finding#W }"$'\n' ;;
  esac
done <<<"$findings"

# A `doc` that names a page nobody ships is a citation that 404s in every answer built from
# it. The checkout is right here, so this costs one `test -f` rather than a broken link
# somebody finds through an agent weeks later. A warning and not an error: the schema
# constrains the type, not the tree, and a page may legitimately be rendered from elsewhere.
# After the structural checks, never before — `.capabilities` is only known to be a list once
# they have passed, and a document that is not an object cannot be walked at all.
if [[ -z "$errors" ]]; then
  cited_docs="$(jq -r '[ .capabilities[] | select(type == "object") | .doc | select(type == "string") ] | unique | .[]' "$CAPABILITY_FILE")"
  while IFS= read -r doc; do
    [[ -n "$doc" ]] || continue
    [[ -f "$doc" ]] || warnings="${warnings}\`${doc}\` is cited by a capability and is not in this checkout, so the citation built from it will not resolve."$'\n'
  done <<<"$cited_docs"
fi

while IFS= read -r warning; do
  [[ -n "$warning" ]] || continue
  tremvok::warn "capability: ${warning}"
done <<<"$warnings"

if [[ -n "$errors" ]]; then
  tremvok::error "capability: '${CAPABILITY_FILE}' does not satisfy ${SCHEMA_URL}"
  tremvok::summary "## Tremvok — the capability declaration is invalid"
  tremvok::summary ""
  tremvok::summary "\`${CAPABILITY_FILE}\` does not satisfy [the capability schema](${SCHEMA_URL}), so \`${key}\` was not written:"
  tremvok::summary ""
  while IFS= read -r problem; do
    [[ -n "$problem" ]] || continue
    tremvok::error "  ${problem}"
    tremvok::summary "- ${problem}"
  done <<<"$errors"
  exit 1
fi

count="$(jq -r '.capabilities | length' "$CAPABILITY_FILE")"
tremvok::log "capability: '${CAPABILITY_FILE}' declares ${count} capability(ies) and satisfies the schema."

if tremvok::is_true "$DRY_RUN" || [[ "$MODE" != "deploy" ]]; then
  tremvok::notice "capability: '${CAPABILITY_FILE}' is valid; not published (mode=${MODE}, dry-run=${DRY_RUN}). There is one key per repository, so only a deploy writes the shared registry."
  tremvok::summary "Capability declaration validated (${count} capability(ies)); not published on a ${MODE}."
  tremvok::set_output capability-published false
  exit 0
fi

tremvok::require CLOUDFLARE_API_TOKEN "cloudflare-api-token"
tremvok::require CLOUDFLARE_ACCOUNT_ID "cloudflare-account-id"

if [[ -z "$WRANGLER_BIN" ]]; then
  tremvok::require WRANGLER_VERSION "cloudflare-wrangler-version"
  WRANGLER_BIN="npx --yes wrangler@${WRANGLER_VERSION}"
fi

# `private` IS THE CORPUS RULE, NOT A SECOND ONE. `gen_docs_index.py` takes it from the
# repository's visibility and fails closed, because the other direction publishes an internal
# runbook on a typo; the MCP applies the identical rule to both documents in this bucket. So
# the published value is the AND of intent and fact: a declaration is public only when it
# asks to be AND GitHub says the repository is public. Two rules for one bucket is one rule
# that eventually disagrees with the other, and the direction it disagrees in is a leak.
if jq -e '.private == false' "$CAPABILITY_FILE" >/dev/null 2>&1; then
  declared_public=true
else
  declared_public=false
fi
# `tr` rather than bash 4's lower-casing parameter expansion: the macOS runners ship 3.2,
# and `portability.bats` greps for the construct — including inside comments.
visibility="$(printf '%s' "$VISIBILITY" | tr '[:upper:]' '[:lower:]')"
private=true
if [[ "$declared_public" == "true" && "$visibility" == "public" ]]; then
  private=false
fi
if [[ "$declared_public" == "true" && "$private" == "true" ]]; then
  tremvok::warn "capability: the declaration asks to be public, but GitHub reports this repository as '${VISIBILITY:-unknown}'. Publishing it as private — a public surface must never serve a document whose repository is not public."
fi

# The stamped copy, never the file in the tree. `commit` and `generated` are the publisher's
# to fill: a file in a repository cannot know which commit it shipped from, and the answer to
# "is this registry stale?" has to come from the object rather than from a memory of a deploy.
staged="$(mktemp)"
trap 'rm -f "$staged"' EXIT

jq --argjson private "$private" \
   --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
   --arg commit "$COMMIT" \
   '. + {private: $private, generated: $generated}
      + (if $commit == "" then {} else {commit: $commit} end)' \
   "$CAPABILITY_FILE" >"$staged"

# `--remote` is load-bearing and its absence is silent, exactly as in `publish-docs-index.sh`:
# without it Wrangler 4 writes to the LOCAL miniflare simulation under .wrangler/state and
# exits 0. A green step, a real file on disk, and nothing in the bucket.
tremvok::log "publishing ${CAPABILITY_FILE} -> r2://${BUCKET}/${key}"

# Deliberately word-split: WRANGLER_BIN is "npx --yes wrangler@x.y.z", several words.
# shellcheck disable=SC2086
$WRANGLER_BIN r2 object put "${BUCKET}/${key}" \
  --file "$staged" \
  --content-type application/json \
  --remote

tremvok::set_output capability-published true
tremvok::set_output capability-key "$key"
# A plain `if`, not `[[ ]] && a || b` inside `$( )`: a false test last in a command
# substitution is how a script under `set -e` exits silently, and this repo has the incident.
visible=public
if [[ "$private" == "true" ]]; then
  visible=private
fi
tremvok::summary "Capability declaration published to \`${BUCKET}/${key}\` — ${count} capability(ies), ${visible}"
tremvok::notice "capability declaration published to ${BUCKET}/${key}"
