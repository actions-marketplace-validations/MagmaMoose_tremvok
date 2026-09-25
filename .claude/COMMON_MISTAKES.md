# Common mistakes

Each of these cost real time. They are here so they cost it once.

## `x="$(… )"` where the last command is a false `[[ ]]` kills the script under `set -e`

A failing `[[ ]]` inside an `&&` list is exempt from `set -e`. A *command substitution* is not:
the substitution's exit status becomes the **assignment's** status, and an assignment is a
simple command. So this is fine:

```bash
[[ -n "$x" ]] && echo "$x"          # survives
{ echo a; [[ -n "" ]] && echo b; }  # survives
for i in 1; do [[ -n "" ]] && echo b; done   # survives
```

and this exits the script:

```bash
body="$(
  printf 'header\n'
  [[ -n "$optional" ]] && printf '%s\n' "$optional"   # ← false ⇒ assignment fails ⇒ set -e
)"
```

It only bites when the optional line is *absent*, which in `deploy-terragrunt.sh` meant: every
push event, immediately after a successful plan. Use `if` blocks inside `$( )`.

## `${{ }}` inside an action.yml DESCRIPTION is evaluated, and `secrets` is not a context

A description is documentation, so an example written in it looks inert:

```yaml
  terragrunt-stack-env:
    description: |
      */prd/*  ARM_ACCESS_KEY=${{ secrets.PRD_STATE_KEY }}      # <- an EXAMPLE
```

GitHub parses every `${{ }}` in the file regardless of where it sits, and `secrets` is not
available to a composite action. The whole action then fails to load, for every consumer, on
every target:

    Unrecognized named-value: 'secrets'. Located at position 1 within expression:
    secrets.PRD_STATE_KEY
    ##[error]Failed to load .../action.yml

Not a lint, not a warning about that one input: the action does not run at all. `github.token`
in a `default:` is fine because `github` IS a valid context, which is what makes this
inconsistent enough to walk into. Write example expressions as placeholders
(`<the production state key>`), never as real `${{ }}`.

Caught by the dogfood `Build site` job, which is the only check that actually loads the action
rather than parsing the YAML. `python3 -c 'import yaml; yaml.safe_load(...)'` passes happily.

## A helper that ends with `set -e` hands errexit back ON to a caller that turned it off

`set +e` is not scoped. A function written as

```bash
run() { set +e; some_tool "$@"; local code=$?; set -e; return $code; }
```

leaves errexit **enabled** when it returns, whatever the caller had. So this:

```bash
set +e            # "I will handle failures myself"
do_plan           # …which internally does set +e … set -e
code=$?           # never reached: do_plan's non-zero return killed the shell
```

exits the script at `do_plan` rather than at `code=$?`, and silently — the status file is
written, nothing is printed, and the step just ends. It bit `terragrunt-run.sh` on the exact
path where a plan reporting "changes" is a *success*, so the symptom was "a plan with a diff
fails and a clean plan passes".

The fix is to stop toggling the global flag: capture with `|| code=$?`, which errexit exempts,
and let callers test the code. A function invoked in a condition (`if f`, `f || …`, `! f`) also
has errexit suppressed for its whole body, so the toggling buys nothing there either.

## FastAPI + `from __future__ import annotations` + a closure dependency = auth silently gone

`create_app()` defined `caller_repository` locally and used
`repository: Annotated[str, Depends(caller_repository)]`. With stringified annotations, FastAPI
resolves against the *module* globals, does not find the closure, and falls back to treating
`repository` as a required **query parameter**. Every authenticated route answered
`422 {"loc": ["query", "repository"]}` — the dependency never ran at all. Keep dependencies at
module level and hang collaborators off `request.app.state`.

## bash 4 syntax passes CI and fails on macOS runners

`${x,,}`, `${x^}`, `mapfile`, `readarray`, `declare -A` are bash 4. GitHub's macOS images ship
**bash 3.2** at `/bin/bash`, so these produce `bad substitution` on exactly one runner OS while
the Linux suite stays green. Use `tr '[:upper:]' '[:lower:]'` and `while IFS= read -r`.
`tests/bats/portability.bats` fails if any come back.

## `set -e` + `pipefail` + a loop that ends on a false test = a pipeline that "found nothing"

`find … | while read …; do is_stack "$d" && printf …; done | sort -u` exits non-zero whenever
the **last** iteration hits an excluded directory. With `pipefail` that fails the pipeline and
`set -e` ends the script. Discovery worked until somebody added a module that sorted last. Use
`if … then … fi` in loop bodies.

## `cmd | tee log` reports *tee's* exit code

The bug an earlier deploy pipeline paid for: a failed deploy "reported success". `pipefail` is set in
every script here for this reason, and `terragrunt-run.sh` buffers to a file rather than piping.

## An empty build directory plus `aws s3 sync --delete` is an outage, and exits 0

`deploy-s3-cloudfront.sh` refuses to sync a source with no files in it. Do not add a flag to
override this.

## A cross-architecture Lambda package fails at the first request, not at deploy

`pydantic-core` is a compiled wheel. arm64 zip on an x86_64 function ⇒ clean apply, green plan,
`No module named 'pydantic_core._pydantic_core'` on request one. `build_api_zip.py --arch` and
the module's `architecture` must agree; the Makefile derives both from `uname -m`.

## A required check that never reports blocks the pull request forever

Which is why `deploy-terragrunt.sh` publishes the check run even when it discovers **zero**
stacks. "This change touches no Terraform" is a success, not silence.

## An unreadable review list is not "nobody approved"

`approval-gate.sh` exits non-zero when it cannot read the reviews. A caller that treats that as
an empty approver list will refuse to apply when it should — or, worse, a caller that treats an
API error as "no objections" will apply when it must not.

## The package cannot be import-tested on a macOS laptop, and that is correct

`build_api_zip.py` fetches **Linux** wheels for the function's architecture. Unzipping it on
macOS and importing `tremvok.aws.handler` fails with `No module named
'pydantic_core._pydantic_core'` — not a bug, the cross-build working. CI's import check builds
for the runner's own architecture first (`uname -m`); the host-independent guard is
`tests/test_build_api_zip.py`, which reads the archive and asserts the `.so` filenames carry
the expected architecture tag rather than trying to load them.

## "Deterministic" held per-installer, which is not deterministic

`build_api_zip.py` used uv when present and fell back to pip. Both are reproducible on their
own — and they lay the target directory out differently, so the same commit built 2796 KiB one
way and 2812 KiB the other. The deploy path compares digests, so that fallback would have
turned "did the code change?" into "which machine built it?". The builder now requires uv and
says so; `tests/test_build_api_zip.py` asserts the refusal.

The general shape: a fallback that silently changes the artifact is worse than no fallback.

## The Lambda execution role does not need to read the deployment package

The natural assumption — the function runs from `s3://bucket/api/x.zip`, so its role must be
able to `GetObject` that — is wrong. Lambda reads the package with the credentials of the
principal that called `CreateFunction`/`UpdateFunctionCode` (Terraform, or the action's deploy
role) and copies it; the execution role is never involved. The grant was in
`modules/tremvok-api/iam.tf` and has been removed.

It is worth naming because it fails *safe*: nothing breaks, so the extra permission stays
forever, and least privilege is only meaningful if the unused half comes out.

## `docker compose` is not available everywhere `docker` is

The org's dind sidecar ships the Docker CLI without the compose plugin, and the failure is
genuinely misleading: `unknown shorthand flag: 'f' in -f`, because docker parses `-f` as its own
flag once it fails to recognise `compose` as a command. Nothing says "the plugin is missing".

`harness.sh` uses `docker run` and there is no compose file any more. One container needs no
orchestrator, and the laptop and the runner now run the identical command.

## `aws --value https://...` downloads the URL instead of storing it

The AWS CLI's *paramfile* feature expands any argument value starting with `http://` or
`https://` into the contents of that URL. Storing a webhook URL in Parameter Store is exactly
the case that trips it, and the error names the wrong thing:

    Error parsing parameter '--value': Unable to retrieve https://hooks.slack.invalid/...

On by default in CLI v1 (`cli_follow_urlparam`). Use `--cli-input-json`, which is not subject to
the expansion on any version — `seed.sh` and the production instructions in
`terraform/README.md` both do.

## Terragrunt buffers plan output, so an unreachable endpoint is a hang and not an error

`terragrunt-run.sh` sends every invocation's output to a file, which is what keeps a plan
excerpt redactable. The cost: a state backend or provider API the runner cannot reach produces
no output and no error, just an idle process until `terragrunt-timeout` (900s) or the job limit.
The log is empty for fifteen minutes and then says the run was killed, which points at
terragrunt rather than at the network.

The usual cause is an IP allowlist on the state backend that does not include the runner's
egress address. `terragrunt-preflight-urls` probes each named endpoint once, bounded at 8
seconds, before the first plan, and prints the egress IP when one does not answer.

Two rules in that check are the ones most likely to be "fixed" by someone who does not know
them: **401 and 403 pass** (an unauthenticated probe of a credentialed endpoint is supposed to
be refused, and being refused is proof of life), and **5xx passes with a warning** (a 502 from
a load balancer still proves DNS, routing and TLS; failing on it would trade a rare real catch
for regular flakes, and a flaky guard gets deleted). Only curl code `000` fails.

## An outage on the push path reads as an unapproved merge unless the exit codes differ

A push to the default branch has no pull request in its event, so the approval that authorises
the apply is found by asking the API which pull request the commit was merged from. Only when
`terragrunt-apply-on-merge` is on: off (the default) a push does not ask at all, which is what
keeps an upgrade from turning a merge into an apply. When it does ask, the question has three
answers, and two of them look identical if only truthiness is checked:

    0   a merged pull request, its number on stdout
    2   the API answered; this commit came from no merged pull request
    1   the API could not be read

Collapse 1 into 2 and an outage becomes "nobody approved", which is either a silent skip of
approved work or, with the branches the other way round, an apply nobody authorised.
`resolve-merged-pr.sh` keeps them apart, and `tests/bats/resolve_merged_pr.bats` asserts the two
codes differ on identical (empty) stdout. `curl --fail` is what makes a 4xx or 5xx exit non-zero
rather than returning an empty list, so removing it silently merges the two answers.

Same shape, one layer up: a script whose stdout the caller captures must put nothing else on
stdout. `resolve-merged-pr.sh` logs its exit-2 reason to **stderr** for that reason, and
`terragrunt-pr-head.sh` prints the sha and nothing else, or the check run is published against
a log line.

## A `! assertion` in the middle of a bats test body cannot fail the test

Bash does not exit on a failing command whose status is being inverted, and bats runs a test
body under `set -e`. So this passes whatever the file holds:

```bash
@test "the secret never reaches the log" {
  run bash "${SCRIPTS}/deploy-terragrunt.sh"
  ! grep -q 'SUPERSECRET' "$GITHUB_STEP_SUMMARY"   # ← observes nothing
  [ "$status" -ne 0 ]
}
```

It only works as the **last** line of the body, where it is the function's return value — so
an assertion that was armed gets silently disarmed the day somebody appends a line after it.
Thirty-two of these were live in `tests/bats`, including every "the credential never reaches
the log" assertion in `terragrunt_deploy.bats`. One of them was not merely inert but wrong:
`terragrunt_pr_override.bats` asserted no request to `/pulls/7` on the no-override path, and
`approval-gate.sh` requests exactly that URL to find the author.

Use `refute <command>` from `tests/bats/helper.bash` (the inversion happens inside the
function, so the call site is a plain command errexit can act on), and write `[[ a != b ]]`
rather than `! [[ a == b ]]`.

Related, and the reason both are here: an assertion has to be able to observe the mutation it
is named for. `tests/bats/preflight_urls.bats` had a test called "the probe does not retry"
that counted stub invocations — but `curl --retry` retries **inside** one invocation, so the
count is 1 either way. Assert on the recorded argv when the thing being pinned is a flag, and
on behaviour when the stub can model it: `resolve_merged_pr.bats` pins `curl --fail` with a
stub that answers the way curl does (body + exit 0 without the flag, nothing + exit 22 with
it), so deleting the flag turns "unreadable" into "no merged pull request" and the test goes
red.

## An approval is state; only an event authorises an apply

`deploy-terragrunt.sh` under `terragrunt-apply: auto` set `may_apply` on `[[ -n
"$approver_list" ]]` alone. A pull request that already carries an approval then applies on
**every** event that reaches the target, so: reviewer approves commit A, author pushes commit
B, the `pull_request` run for B reads the same standing approval and applies B. Nobody reviewed
B. It only looks safe on a repository whose branch protection dismisses stale reviews on push,
which the action cannot see and must not assume.

The rule: read the approval to know the change **may** be applied, and the event to know an
apply was **asked for now**. Here that is a `pull_request_review` whose review is an approval,
or the merged-push path with `terragrunt-apply-on-merge` on. Neither `workflow_dispatch` nor a
COMMENTED review is an approval of the commit in front of you. `EVENT_NAME` is the one source
for the event; do not re-derive it beside `resolve-mode.sh`.

## Copying the estate pipeline's `stack_is_affected` verbatim plans the whole subtree

That function walks every ancestor of the changed path that is still inside `terraform/`, and
for each one matches every stack beneath it. Read quickly it looks like "a shared file affects
the stacks under it". It is not: the walk keeps climbing, so `terraform/<estate>/<a>/<b>/x.tf`
reaches `terraform/<estate>` and sweeps **every** stack in that estate. Checked against the
real tree, a file inside one stack maps to 23 stacks under that algorithm and to 1 under
`terragrunt-discover.sh`; a file under `_modules/` maps to 23 there and to 0 here.

So the walk-down was taken and the climb was not: a changed path with no enclosing stack maps
to the stacks beneath **its own directory** (`dirname`, once), which is what makes a shared
`root.hcl` mean its own subtree and leaves the deliberate "a module maps to nothing" rule
standing. Both scripts agree exactly on the case the fix was for: 23 and 5 stacks for the two
shared roots in that tree.

## A target in `preflight.sh`'s AWS-credential list is a target that cannot run without AWS

Every terragrunt step in `action.yml` is gated on `steps.preflight.outputs.skip != 'true'`, so
naming `terragrunt` in that credential check did not degrade the run, it deleted it: no plan,
no check run, an `::notice::` and a green job. Terragrunt is provider-agnostic and
`terragrunt-stack-env` exists to carry an Azure or other backend credential, so the only
targets that belong in that list are the ones whose own scripts call `aws`.


## `az functionapp deployment source config-zip` exits non-zero over a deploy that worked

Observed, repeatedly:

```text
ERROR: Operation returned an invalid status 'Bad Request'
```

with an exit status to match — and `WEBSITE_RUN_FROM_PACKAGE` pointing at the newly uploaded
blob, and the app serving the new code. The CLI is reporting a poll of its own status
endpoint, not the outcome of the deploy.

Both obvious fixes are wrong. Failing on the exit code fails green deploys; appending
`|| true` hides the real failures, which look identical from outside. So
`deploy-azure-functions-zip.sh` does neither: on a non-zero exit it asks the platform whether
`WEBSITE_RUN_FROM_PACKAGE` actually moved, warns and continues if it did, fails if it did not
— and then, either way, the app has to answer before the run is called a success.

Do not "simplify" this into a plain `||`. `tests/bats/azure_functions.bats` pins both
directions.

## A Functions zip built the obvious way deploys cleanly and serves nothing

The worker discovers functions from `functions.metadata` and loads the host extensions from
the dotfile directory `.azurefunctions/`. Both must be at the **archive root**. Two ordinary
ways of building the zip put them somewhere else:

```bash
zip -r package.zip publish        # nests everything under publish/
cd publish && zip -r ../x.zip *   # the glob skips dotfiles: no .azurefunctions/
cd publish && zip -r -q ../x.zip . # correct
```

Neither broken package errors. The deploy succeeds, the app starts, and every route 404s with
no log line saying why. That is why the guard reads entry *names* rather than grepping the
archive's bytes: a nested package contains the literal text `publish/functions.metadata`, so a
substring match passes the exact mistake it exists to catch.

## A cancelled plan strands the state lock, and every pull request that plans that stack fails

A `terragrunt` plan takes the backend's state lock. The caller cancels a pull-request run whenever
a newer push or review arrives, and a cancelled `tofu` can be killed before it releases the lock:
the runner signals the step's own process and follows with a SIGKILL of the tree, so the signal
may never reach `tofu`. Every later run then plans its stacks in turn, reaches the locked one,
waits out `-lock-timeout=5m` and fails the whole job with

    Error acquiring the state lock ... state blob is already locked

whatever its pull request changes. One plan cancelled 15 seconds after it took the lock on one
stack failed every pull request that planned that stack for hours, and a change under a shared
module plans every stack, so most did. The job log names the lock (`ID`, `Path`, `Who`,
`Created`); it stayed until somebody ran `tofu force-unlock <ID>`. On `azurerm` the lock ID is
also the blob lease ID.

A plan writes nothing to state, so the runs a newer event cancels and that never apply
(`pull_request`, and a `pull_request_review` that does not approve) plan with `-lock=false`
(`terragrunt-plan-lock`). Anything that can apply keeps the lock, and an apply always locks,
including the re-plan inside one. `tests/bats/terragrunt_run.bats` and
`tests/bats/terragrunt_deploy.bats` pin each event.

## A Linux Consumption Function App on `DOTNET-ISOLATED|10.0` never starts

The platform offers it and `az functionapp create` accepts it. The app then returns 503 from
the site **and** from its SCM endpoint, with no log output at all, so there is nothing to
diagnose. `9.0` started first try with a byte-identical package. Verified 2026-09-11.

Related, and the reason this target verifies by HTTP rather than by asking Azure: an
`azurerm_linux_function_app` in that state reports `state: Running` and
`availabilityState: Normal`. Platform state is not evidence that anything is being served.

## `actions/upload-pages-artifact` leaves out every dotfile, so `.well-known/` never ships

From v4 the action tars the site with `--exclude=.[^/]*` unless `include-hidden-files` is
`true`. The agent-readiness step writes `/.well-known/agent-skills/index.json` into the built
site, the artifact drops it, and GitHub Pages serves the site without it: a 404 at the one path
a client reads, and no warning anywhere, because nothing failed. Cloudflare's Wrangler uploads
dot-directories, so the same build on `cloudflare-docs` looks fine, which is what makes this
look like a Pages problem rather than a Tremvok one.

The Stage step passes `include-hidden-files: ${{ inputs.pages-agent-ready }}`, tied to the input
so that turning the step off stages exactly what it staged before. `.git` and `.github` are
excluded either way. `tests/test_gen_docs_agents.py` pins the wiring.

## A browser script served as `fn.toString()` passes in Node and throws from the bundle

The router's landing page script was first a function in `workers/docs-router/src/webmcp.js`,
served as its own source text, so the code was parsed at import and testable in Node. Every
test passed. Wrangler bundles with esbuild's `keepNames`, which rewrites each named function
and arrow into `__name(fn, "fn")`, where `__name` is a helper defined at the top of the bundle.
The served text then called a function that exists in the Worker and not in the page:

    ReferenceError: __name is not defined

before a single tool registered, on the one page whose job was to register them. The script is
a `String.raw` template now, served byte for byte whatever the bundler does, and
`tests/test_workers_bindings.py` runs the dry-run bundle's `/webmcp.js` in an empty context so
that going back to `toString()` fails CI. The general rule: anything the router sends to a
browser is data, never a function's source.
