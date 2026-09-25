# Tremvok

A published Marketplace action: one composite action, nine targets (`github-pages`,
`s3-cloudfront`, `lambda-zip`, `terragrunt`, `ansible`, `cloudflare-workers`, `cloudflare-docs`,
`azure-functions-zip`, `azure-apim-policy`), plus an optional FastAPI deployment-record service on Lambda. Consumers pin `@v2` and a broken release breaks
their deploys, so the action's input contract is the thing to be careful with. Infrastructure is
`terraform/`, provable on LocalStack.

@.claude/QUICK_START.md
@.claude/ARCHITECTURE_MAP.md

`CLAUDE.md` is canonical. `AGENTS.md` restates the same rules for agents that do not read this
file; edit the two together.

## Footguns — read `.claude/COMMON_MISTAKES.md` before debugging any of these

Twenty-seven incidents, each with symptom, cause and fix. The clusters:

- **A script exits silently under `set -e`** — a false `[[ ]]` last in `$( )`, a helper that
  re-enables errexit, a loop ending on a false test, `cmd | tee`.
- **Green on Linux, `bad substitution` on macOS** — bash 4 syntax; the runners ship 3.2.
- **A FastAPI route answers 422 `{"loc":["query","repository"]}`** — the auth dependency stopped
  being a dependency.
- **The Lambda imports fine locally and dies on request one** — architecture, installer
  determinism, and why the zip cannot be import-tested on a laptop.
- **A gate that reports the wrong thing** — a required check that never reports, an unreadable
  review list read as "nobody approved".
- **An AWS call that does something other than what it says** — `sync --delete` on an empty
  build, `--value https://…` fetching the URL, an IAM grant that was never needed, `docker
  compose` missing where `docker` is present.
- **Something the build wrote that never reaches the browser**: `upload-pages-artifact`
  dropping `.well-known/`, a script served as `fn.toString()` from an esbuild bundle.

## Hard constraints

- **Tremvok's own hosted components are AWS** — the API is Lambda, not a Worker — inside the
  always-free allowances; new spend needs a recorded decision, not a default. A caller's deploy
  *target* is a different thing: it runs on their account at their cost, so any supported
  provider is fine, `cloudflare-workers` included. See
  `.claude/decisions/0003-cloudflare-workers-target.md`. Exception: `workers/docs-router/` is
  MagmaMoose org infrastructure (fleet-wide, not Tremvok's backend), sourced here because this
  is the docs toolchain. See `.claude/decisions/0004-docs-on-workers-static-assets.md`.
- **Bash 3.2.** GitHub's macOS runners ship it. No `${x,,}`, `${x^}`, `mapfile`, `declare -A`.
  `tests/bats/portability.bats` enforces this.
- **Secrets are SSM `SecureString`.** Never Lambda environment variables, never Terraform
  resources.
- **Notification sinks are failure-isolated.** A deploy that succeeded never fails because a
  webhook did.
- **Never hand-edit `scripts/lib/input-targets.json`.** It is generated; regenerate after any
  input change or CI fails. See ARCHITECTURE_MAP.
- **Bash on the runner, Python off it.** Target adapters are bash. Python is for the generators,
  linters, packager and tests — none of which run on a caller's runner in the deploy path.

## Finding code

- Before locating unfamiliar code, read `./PROJECT_INDEX.json`.
- `AGENTS.md` = full editing rules. `README.md` = the user guide. `terraform/README.md` = costs
  and the LocalStack gaps. `docs/migration.md` = the v1→v2 input renames.
- Load `.claude/decisions/` (ADRs) and `.claude/sessions/` ONLY when the task relates to them.
- Human docs are `./docs` (MkDocs); `.claude/*.md` is terse agent context. Keep them distinct.

## [tooling]

- Prefer targeted line-range reads over whole files. `action.yml` is long; read the input block
  you need, not the file.
- grep/find/glob: return matching paths and matched lines only.
- Commands that can flood output (test runs, terraform plans): pipe through `head`/`tail`/`grep`
  or redirect to `.claude/last_output.txt` and read ranges.
- After a successful write/edit, trust it; don't re-read to "verify".

## [maintenance]

- Bug that took >1h: append to `.claude/COMMON_MISTAKES.md`.
- Architectural decision: run `/adr`.
- Public behaviour/API/config/setup changed: run `/update-docs`.
- Keep this file under ~500 tokens; push detail into on-demand `.claude/` files.
