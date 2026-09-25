# Contributing to Tremvok

> `CLAUDE.md` is the canonical agent-context file; this file restates the same rules in full for
> agents that do not read it. **Edit the two together** — two files of record that drift apart
> are worse than one, because then the agents disagree and neither is wrong.

Tremvok has two surfaces in one repository. They talk over HTTP and **neither imports the
other**; a change that couples them is the change to push back on.

| Surface | Lives in | Language | Tests |
|---|---|---|---|
| Composite action | `action.yml`, `scripts/*.sh` | bash (**3.2-compatible**) | `bats tests/bats` |
| API | `src/tremvok/` | Python 3.12, FastAPI | `uv run pytest` |
| Infrastructure | `terraform/` | OpenTofu ≥ 1.9 | `make -C terraform dev` |

## The rules that are not negotiable

1. **Tremvok's hosted components are AWS; a caller's target need not be.** Everything Tremvok
   itself runs — the API on Lambda, DynamoDB, everything in `terraform/` — is AWS, inside the
   always-free allowances. Anything that costs money outside them needs a decision recorded in
   `terraform/README.md`, not a default. A deployment *target* is a different thing: it runs in
   the caller's account, on the caller's bill, so any supported provider is fine, and
   `cloudflare-workers` is one of them. The API stays Lambda; a Worker is not an alternative
   home for it. See `.claude/decisions/0003-cloudflare-workers-target.md`. Exception:
   `workers/docs-router/` is MagmaMoose org infrastructure (fleet-wide, not Tremvok's backend),
   sourced here because this is the docs toolchain. See
   `.claude/decisions/0004-docs-on-workers-static-assets.md`.
2. **bash 3.2.** GitHub's macOS runners ship it. No `${x,,}`, `${x^}`, `mapfile`, `readarray`,
   `declare -A`. `tests/bats/portability.bats` fails the build if one comes back.
3. **`action.yml` is glue.** Logic goes in `scripts/`, where it can be tested. If you find
   yourself writing a condition in YAML that is not a step `if:`, it belongs in a script.
4. **Notification sinks are failure-isolated.** They warn; they never fail the job. A *deploy*
   failure always fails the job.
5. **Secrets are SSM `SecureString`.** Never a Lambda environment variable (plaintext to
   `lambda:GetFunctionConfiguration`), never a Terraform resource (a secret in state).
6. **`scripts/build_api_zip.py` is the only definition of what ships.** CI must not assemble a
   package another way; a local build and a released artifact built differently is a difference
   nobody finds until production.
7. **Every guard gets a test that names the failure it prevents.** The tests here are the
   documentation of what went wrong once.
8. **`scripts/lib/input-targets.json` is generated, never hand-edited.** It is what
   `validate-inputs.sh` reads at runtime and what the reference page is built from. Regenerate
   with `python3 scripts/gen_input_targets.py` after any input change; CI fails on drift.
9. **Bash on the runner, Python off it.** Target adapters are bash, under `bats`. Python is for
   the generators, the linters, the packager and the tests — none of which run on a caller's
   runner in the deploy path. Adding one to an adapter costs every AWS run a `setup-python`
   step and puts that code outside the contract the bats suite enforces.

## Local validation

Run all four before opening a pull request:

```bash
shellcheck -S warning scripts/*.sh scripts/lib/*.sh
bats tests/bats
uv run ruff check . && uv run ruff format --check . && uv run pytest -q
make -C terraform validate
```

And, when you touched the API or the infrastructure:

```bash
make -C terraform dev      # LocalStack, end to end
```

## Adding a target adapter

1. `scripts/deploy-<target>.sh`, sourcing `lib/common.sh`, reading its inputs from environment
   variables, writing `deployed` and whatever else it produces with `tremvok::set_output`.
2. Inputs in `action.yml` named `<target>-*`, each description **opening with
   `<target>: `** — that prefix is what `scripts/gen_input_targets.py` reads to build the
   applicability map, so the reference page and the runtime check come from one source. An
   input shared by several targets opens with all of them, comma-separated.
3. A step in `action.yml` gated on `inputs.target == '<target>'`, and the new value added to
   `TARGETS` in `scripts/gen_input_targets.py`.
4. Regenerate both build products, which CI checks:
   `python scripts/gen_input_targets.py && python scripts/gen_action_reference.py`.
5. `tests/bats/<target>.bats`, stubbing the tool with `stub_script` so the exact command line
   is asserted — especially the flags that only matter when they are wrong.
6. A row in the README's most-used inputs table, a section in `docs/setup.md`, and a file in
   `examples/`.
7. If the target can fail *silently*, a guard plus a test, plus a line in
   `.claude/COMMON_MISTAKES.md`.

**Verification is the thesis.** Every target has to be able to answer "did it actually take
effect?" with something stronger than an exit code — a URL that answers, a header that is
present, a `CodeSha256` that matches, a second check-mode run that finds nothing to change. A
target that can only report that it ran is not finished.

## Changing the API's wire contract

`models.py` is the contract. `DeploymentIn` has `extra: "forbid"`, so adding a field to the
action's payload without adding it to the model is a 422, not a silent drop — which is the
behaviour we want. `repository` must never become a request field: it comes from the OIDC
token's claim, and that is what makes cross-repository writes inexpressible rather than merely
rejected.

## Commits and releases

- Conventional Commits. Branches are `<type>/<description>` or `<type>/<scope>/<description>`.
- Actions are SHA-pinned with a trailing `# vX.Y.Z` comment.
- Releases are cut by Diatreme (`versioning-tool: semantic-release-python`); the version lives
  in `src/tremvok/__init__.py` and nowhere else. Do not bump it by hand.
