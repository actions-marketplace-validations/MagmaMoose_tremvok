# Troubleshooting

<!-- sources: scripts/, src/tremvok/oidc.py, src/tremvok/api/app.py -->

Every entry here is an error the action or the API actually emits. The message is quoted as it
appears in the log.

## Inputs and setup

### `these inputs do not apply to target: <target>`

The run passed an input belonging to a different target. The log names each one and where it
belongs, and lists all of them at once so you fix them in one pass rather than one per run.

This fires before the checkout, so it costs a couple of seconds. Check the "Applies to" column
in the [action reference](action-reference.md), or drop the input.

There's one thing this can't catch: an input set explicitly to the value it already defaults to.
GitHub gives a composite action no way to tell "unset" from "set to the default". An input
holding its default changes nothing, so the blind spot is harmless.

### `unknown target '<value>'`

`target` accepts `github-pages`, `s3-cloudfront`, `lambda-zip`, `terragrunt`, `ansible` or
`cloudflare-workers`. The message lists them. There's no default, on purpose: guessing
`github-pages` would silently build a site for someone who meant to deploy a Lambda.

### `Tremvok skipped: this pull request comes from a fork`

Working as designed. A fork can't read your secrets, so the credential is empty and the deploy
would fail with an authentication error that looks like a broken credential rather than a policy
doing its job. The run reports a skip with the reason instead.

`allow-fork-preview: true` exists and is almost always wrong: it converts an honest skip into an
auth error.

### `Tremvok skipped: no AWS credential is available for target: <target>`

Only `s3-cloudfront` and `lambda-zip` raise this, the two targets that call AWS themselves. Set
`aws-role-to-assume`, or configure credentials in an earlier step.

No other target sees it. `github-pages`, `cloudflare-workers` and `ansible` publish somewhere
else, and `terragrunt` takes its credentials from the backend and provider blocks in your own
configuration, which may name AWS, Azure, GCP, a private cloud, or several in one run. Skipping
any of them for a missing AWS credential skips a run that never needed one. If a terragrunt run
does need AWS and has none, terragrunt fails in the provider with a message naming it, which is
the more useful error. Before this was fixed, a terragrunt run with no `aws-role-to-assume` was
skipped outright: every terragrunt step is gated on this skip, so the target quietly did
nothing.

### `could not configure AzureCli Authorizer: ... Please run 'az login'` during a terragrunt plan

Or `exec: "az": executable file not found in $PATH`, which is the same problem on a runner
without the CLI installed.

The state backend has a credential and the **provider** does not. They are different
credentials from different chains: `terragrunt-stack-env` supplies the first, which is why
`init` reads and writes state perfectly well and the failure only arrives once the plan
reaches `provider "azurerm"`. An `ARM_ACCESS_KEY` opens one storage account; it cannot
configure a provider.

Set `azure-client-id`, `azure-tenant-id` and `azure-subscription-id` — the action signs in
with this run's OIDC token before the first plan. Or run `azure/login` in an earlier step, or
hand the stacks `ARM_CLIENT_ID` and a secret through `terragrunt-stack-env`. See
[Setup](setup.md#credentials-for-the-providers-which-are-not-the-state-backends).

### `N stack(s) declare a provider with no credential on this runner`

`terragrunt-credential-preflight` caught the failure above before the first plan rather than
twenty stacks into it. The summary names the cloud, the stacks and the fix.

If it is wrong — the credential is there and the check cannot see it — the useful question is
*how* the provider authenticates. A provider block that configures its own authentication is
not checked at all, so a stack reading `client_id` from a variable is already exempt. What is
left is a chain this action does not know about, and `terragrunt-credential-preflight: warn`
is the escape hatch; `off` turns it off entirely. Both are worth a moment's thought first: the
error it replaces costs a full plan cycle across every stack to say less.

### `Google STS refused the OIDC token for <provider>`

The federation itself, not the permissions. The pool provider's issuer URI or its attribute
condition does not match this run. Check the issuer is the one your enterprise actually mints
tokens from (on GitHub Enterprise Cloud with data residency that is
`https://token.actions.<subdomain>.ghe.com`, not `token.actions.githubusercontent.com`), and
that the attribute condition allows this repository and ref. The message carries Google's own
`error_description` when there is one.

### `the federated identity may not impersonate <service account>`

The opposite half: the pool accepted the token and the service account will not be
impersonated. Grant the pool's `principalSet` `roles/iam.workloadIdentityUser` on that service
account. Or drop `gcp-service-account` entirely and bind the roles to the principalSet, which
is one fewer indirection.

### `gcp-workload-identity-provider must be the provider's full resource name`

A pool is not a provider. It is
`projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<provider>` — the
project **number**, not its id. Refused before any call, because Google answers a pool name
with a 400 about an invalid audience that names neither the pool nor the provider.

### `terragrunt-credential-preflight must be auto, warn or off`

It is an enum, not a boolean. `true` and `false` are refused rather than read as one of them.

### `role-to-assume is set but this job cannot mint an OIDC token`

Add `permissions: id-token: write` to the job. Without it, GitHub doesn't hand the runner a
token to exchange.

### `STS refused to assume <role-arn>. Check the role's trust policy allows this repository and ref.`

The role exists and the token is valid, but the trust policy doesn't match this run. The usual
cause is a `sub` condition scoped to a branch the run isn't on. See
[Setup](setup.md#an-iam-role-the-workflow-can-assume) for the policy shape, and note the
`StringLike` on `sub` should carry a `ref:` prefix rather than `repo:owner/name:*`.

### `build-git-credentials line <n> has no ':' between the username and the token`

A line is exactly `<host> <username>:<token>`. The username is written out rather than
guessed, because the forges disagree: `x-access-token` for a GitHub App installation token,
`oauth2` for a GitLab one.

Every message from this input names the line by its index and its host and stops there. The
token is never shown, and neither is the line, because the annotation carrying it is as public
as the repository. Count blank lines and `#` comments when you go looking for line `<n>`: the
index names the line you typed.

### `build-git-credentials line <n> has a token under 8 characters`

Refused rather than used. A real token is never that short, so this is a truncated paste —
usually a secret that resolved to nothing because it isn't set on this repository, leaving the
line half-formed. Masking a string that short would be worse than not masking it: every
occurrence of those few characters in every later line of the log would turn into asterisks.

### `build-git-credentials line <n> starts with a URL, not a host` / `does not start with a host`

Write the bare host — `git.example.invalid`, not `https://git.example.invalid/org/repo.git`.
The rewrite is built from it, and it has to match the host in the dependency URL exactly or
git never applies it. Both refusals name the line by index alone: what's in that field may
itself be a credential.

### `build-git-credentials names host <host> twice`

Two rewrites for one host, and which one git picks isn't defined, so the credential in use
wouldn't be the one you can read off the input. One line per host; if two builds need
different tokens for the same host, they need different jobs.

### `GIT_CONFIG_COUNT holds '<value>', which is not a number`

Something earlier in the job set `GIT_CONFIG_COUNT` to something git can't read. This step
extends that count rather than starting again at 0, so a rewrite an earlier step configured
survives; it can't do that against a value it can't parse. Fix or unset the variable.

### The build still can't clone, and nothing was refused

The rewrite only fires on an exact host match. Check the host in the line is spelled the same
as the host in the dependency URL, and that the token is scoped to the repository being
cloned: an installation token reaches only the repositories its installation was given, and
the clone fails with git's own `Authentication failed` rather than anything Tremvok prints.

## `target: github-pages`

### `no uv.lock and no docs/requirements.txt — cannot tell how to install MkDocs`

Detection looks for `uv.lock` first, then the file named by `pages-requirements`. If your repo
has neither, set `pages-toolchain` to `uv` or `pip` explicitly.

### `pages-toolchain must be auto, uv or pip (got '<value>')`

The only three values. `auto` is the default and is right almost always: `uv.lock` in the tree
is the fact, and a caller restating it in config is one more thing that can disagree with the
repo.

### `no mkdocs.yml in <dir> — nothing to build`

`working-directory` doesn't point at the directory holding `mkdocs.yml`.

### The build passed but nothing was staged for the Pages deploy

Expected on a pull request, and there's no input to change it. GitHub Pages has one site and
no preview destination, so a run in `mode: preview` (which is what a pull request resolves to)
builds and checks without staging an artifact, and `dry-run: true` does the same. The run
summary says `staging a Pages artifact: false`; the log says `stage-pages=false`. On a push
to the default branch both say true.

If a push also staged nothing, check the job summary for a skip: a fork pull request and an
unwired repository both report one with a reason.

### `gen-docs-agents: site_name '<name>' gives no Agent Skills name`

The skill is named after `site_name`, lowercased, with every run of anything but letters and
digits turned into one hyphen, and a `site_name` with no Latin letter or digit in it leaves
nothing to name it by. Set `extra.agents.skill.name` to a name of `a-z`, `0-9` and single
hyphens. The rest of the agent-readiness step still runs; only the skill is left out.

### The published site has no `/.well-known/agent-skills/index.json`

Check that the step ran (`pages-agent-ready`, on by default) and that the site does not already
publish its own `/.well-known/agent-skills/`, which the step keeps whole. On `github-pages` the
Pages artifact includes dot-directories only while `pages-agent-ready` is on, because
`actions/upload-pages-artifact` leaves them out otherwise. On a host shared through the docs
router, a site's skill appears in the host's root index within five minutes of its deploy, the
time the router keeps what it last read from each site.

## `target: s3-cloudfront` and `target: lambda-zip`

### `artifact-path '<path>' is not a directory` / `is not a file` / `is empty`

The build step didn't produce what the deploy expects: a directory for `s3-cloudfront`, a `.zip`
for `lambda-zip`.

!!! warning "The empty-directory refusal is deliberate"
    An empty build directory plus `aws s3 sync --delete` empties the live site and exits `0`.
    The refusal is what stands between a build that quietly produced nothing and an outage. Don't
    add a flag to override it.

### `Lambda reports CodeSha256 <a> but the artifact is <b>. The function is not running the package this run built.`

The update was accepted and the function is serving different code. Usually a concurrent deploy,
or an update that targeted a different function or alias. "The API accepted my request" is not
"the function runs my code", which is why this check exists.

### `No module named 'pydantic_core._pydantic_core'` on the first request

A cross-architecture package. The deploy succeeded because nothing loads the code until a request
arrives. `build_api_zip.py --arch` and the module's `architecture` must agree. See
[Configuration](configuration.md#terraform-module-variables).

Unzipping the package on a macOS laptop and importing it fails the same way, and that one is
correct: the builder fetches Linux wheels for the function's architecture.

## `target: cloudflare-workers`

### `CLOUDFLARE_API_TOKEN is required` / `CLOUDFLARE_ACCOUNT_ID is required`

The log names the input that supplies each one, `cloudflare-api-token` and
`cloudflare-account-id`. Both are checked before anything is installed or built, so a missing
secret costs a second rather than a build. The usual cause is a fork pull request, which can't
read secrets, and which the preflight skip normally catches first.

Mint the token from Cloudflare's "Edit Cloudflare Workers" template rather than a hand-picked
permission list, or the first deploy of a custom domain fails on a permission nobody thought
to grant. `WRANGLER_VERSION is required` is the same guard: you blanked
`cloudflare-wrangler-version`, and the tool that publishes to production is not a floating
dependency.

### `artifact-path '<path>' is not a directory`

`artifact-path` is the Worker's asset directory for this target, passed to Wrangler as
`--assets`. Either the build step didn't run, or it wrote somewhere else. Leave the input empty
if the asset directory in your Wrangler config is the one you want.

### `artifact-path '<path>' has no files in it. Refusing to publish an empty asset directory over a site that is currently serving.`

The build produced nothing and the deploy would have replaced a working site with it. Same
refusal as the S3 target, for the same reason.

!!! warning "There is no flag to override this"
    A build that quietly produced nothing is indistinguishable from a successful one right up
    until the site is empty. The refusal is the only thing standing between the two.

### `preview mode needs a preview-alias`

`mode: preview` uploads a version under an alias, and the alias is what makes that version
reachable without touching production. It's `pr-<number>`, resolved from the event, so this
means preview mode with no pull request behind it: usually `mode: preview` forced on a push.
Let `mode: auto` resolve it, or run `mode: deploy`.

You normally hit the earlier form of the same problem first, `preview mode needs a
pull-request number or an explicit preview-alias`. The deploy step checks again anyway,
because a preview uploaded under no alias is a version nobody can reach.

### `unsupported mode '<mode>' for target cloudflare-workers (expected deploy or preview)`

`mode: rollback` is accepted by `s3-cloudfront` and `lambda-zip`, where it behaves exactly
like a deploy: it publishes whatever artifact you hand it. Point `artifact-path` (or
`lambda-version-label`) at the older build and it re-publishes that. What no target does
is look up deployment history and pick the previous version for you. `terragrunt`,
`ansible` and `cloudflare-workers` refuse the mode outright rather than pretend.

### `wrangler exited <n>`

Wrangler's own failure, and its output is above the message in the log. The code is
Wrangler's own, not `tee`'s: `pipefail` is set for exactly this, so a failed publish can't
report success. The two that aren't obvious from the output are a token that authenticates but
lacks a permission (mint it from the "Edit Cloudflare Workers" template), and a route or custom
domain already claimed by another Worker, which fails at the bind after a successful upload.

## `target: terragrunt`

### `terragrunt-stack-env line <n> has a glob but no KEY=VALUE after it`

Every non-blank, non-comment line is `<glob>` then whitespace then `KEY=VALUE`. A glob on
its own is refused rather than skipped, because a silently dropped line means a stack runs
with no credential and fails at `init` with something far less specific. The companion message
is `line <n> does not assign a KEY=VALUE`, for a line whose KEY does not start with a letter
or an underscore.

The line itself is never printed. This input carries credentials, and the annotation it would
appear in is as public as the repository, so the message names the line by its index (counting
blank and comment lines, so it matches what you typed), the glob, and the KEY — never anything
at or after the first `=`. A line with no whitespace on it at all, `ARM_ACCESS_KEY=…` with the
glob forgotten, is reported as `ARM_ACCESS_KEY=<redacted>` for the same reason.

### A stack initialises against the wrong state account

Order decides it: the first matching line wins for a given key, so a `*` catch-all above a
`*/prod/*` pattern captures everything. Put the specific pattern first.

### `<n> stack(s) failed to plan`

The pull-request comment carries a redacted excerpt for each stack that changed or failed, sized
so the whole comment fits GitHub's limit; the workflow run has every plan in full. Nothing
applies while any stack fails to plan, approval or not.

### `<actor> is not in terragrunt-apply-operators, so cannot force an apply`

`terragrunt-apply: force` skips the approval, so it needs its own authorisation. Empty
`terragrunt-apply-operators` means nobody, and the run refuses rather than applying on the
strength of a flag. The normal path is an independent pull-request approval and needs no list.

### The check run says `Apply required before merge` and stays amber

That's the intended state for a pull request with pending changes. It turns green once the stacks
are applied, which is what makes apply-before-merge enforceable. Get an independent approval:
approving applies the stacks.

### The check run says `Approved, but not applied for this commit`

The pull request carries an independent approval, but this run was not started by it, so it
planned and reported instead of applying. An approval applies the commit it was given for: the
usual way to see this is an approval on one commit followed by a push of another, where
applying the new one would apply a commit nobody reviewed.

Dismiss the approval and re-approve to apply the commit in front of you. If the workflow has no
`pull_request_review` trigger, add one (`types: [submitted, dismissed]`) or nothing will ever
apply. `terragrunt-apply: force` applies by hand for an actor named in
`terragrunt-apply-operators`.

The same state appears when the run was triggered by a review that is a comment or a change
request rather than an approval, and on a `workflow_dispatch` that names a pull request with
`terragrunt-pull-request`: dispatching a workflow is not approving a commit, so that path plans
and `terragrunt-apply: force` is its apply.

### `could not read the reviews of #<n>`

The API call failed. The run refuses to apply rather than treating an unreadable review list as
"nobody objected". Retry, or check the token has `pull-requests: read`. On a push to the
default branch with `terragrunt-apply-on-merge: true` this also **fails the run**, after
publishing the check run and the comment: nothing blocks a merge that has already happened, so
a quiet skip would leave stacks unapplied with nobody told. It fails only when there were
pending changes it would have applied. A merge whose stacks all plan clean reports success,
because refusing to apply nothing is not a refusal.

### The check run says `Planned; not applied`

Real changes were found and none were applied, on a run with `terragrunt-apply-on-merge: true`
and no open pull request: a push whose commit came from no merged pull request, one merged
without an independent approval, or the scheduled drift run, which never applies. `neutral`
rather than `action_required` on purpose: this check lands on a commit that is already on the
branch, so there is no merge left to block, and turning the default branch red is not what
fixes an unapproved merge. The stacks stay unapplied and the scheduled drift run keeps
reporting them. Apply them with `terragrunt-apply: force` and an actor named in
`terragrunt-apply-operators`, or fix the branch protection that let the merge through.

With `terragrunt-apply-on-merge` off, which is the default, the same run reports
`Apply required before merge` exactly as it always has. `neutral` is the better answer for a
commit nothing is waiting on, but it is still a different answer, so it is gated on the input:
a caller who opts into nothing keeps the conclusion they already have.

### `could not read the pull requests for <sha>`

Only reachable with `terragrunt-apply-on-merge: true`. The commit-to-pull-request lookup
failed, so the run cannot tell which pull request authorised the merge, which means it cannot
tell whether it was approved. It fails rather than guessing, but not before the check run and
every step output are published, so a required check is never left never reporting on that
commit. There is no plan comment on this path: the lookup is the thing that would have said
which thread to comment on. "Answered, and this commit came from no merged pull request" is a
different answer and is handled differently, which is the whole point of keeping the two
apart. Retry, or check the token has `pull-requests: read`.

Like the unreadable review list above, it fails only when there were pending changes it would
have applied: a merge whose stacks all plan clean reports success and warns, because refusing
to apply nothing is not a refusal. Under `terragrunt-apply: never` it only warns too, because
that mode never consults an approval.

### The log says `terragrunt-apply-on-merge is off, so a push plans and applies nothing`

Working as configured, and this is the default. A merge to the default branch plans the
affected stacks and applies none of them, which is what this target has always done. Set
`terragrunt-apply-on-merge: true` to have a merge that had an independent approval apply what
it merged.

### `terragrunt-pull-request: '<value>' is not a pull-request number`

Digits only. The value becomes a path segment in a GitHub API URL, so it is checked in the
action's first step, before the checkout, the tofu and terragrunt download and the assume-role.

### `could not read pull request #<n> from <owner/repo>`

`terragrunt-pull-request` names a pull request this run cannot see: a wrong number, or a token
without `pull-requests: read`. The run ends there, before any discovery, `init` or `plan`, so
nothing is half-applied and no state lock is taken.

### `the checked-out tree does not contain #<n>'s head commit <sha>`

A warning, not a failure. Tremvok never checks out a merge ref: it plans whatever is on disk,
and the `ref:` is your own `actions/checkout` step's business. This usually means
`terragrunt-pull-request` was set without `ref: refs/pull/<n>/merge` and `checkout: false`, so
the plan is of the default branch's code against that pull request's file list. It is a warning
because `checkout: false` with a partial tree is a legitimate choice.

### `<n> of <m> preflight endpoints are unreachable from this runner`

`terragrunt-preflight-urls` got no answer at all from those endpoints, which is DNS,
connection refused, a connect timeout, a TLS handshake failure or a proxy refusal. The line
above each one carries curl's own exit code, which says which: 6 DNS, 7 refused, 28 timeout,
35 or 60 TLS. The step also prints the runner's egress IP, which is what to add if the endpoint
is IP-allowlisted. This runs before the first plan on purpose: terragrunt buffers plan output
to a file, so the same failure without it is a silent wait until `terragrunt-timeout`.

A `401` or `403` is **not** a failure here, and an endpoint that passes has not proved your
credential works. This check only asks whether anything is listening.

### `terragrunt-preflight-urls line <n> carries credentials in the URL`

A line of the form `https://user:password@host/`. These URLs reach the run log, which is public
on a public repository, so the run refuses rather than probing it. The message names the line
by its index and shows the URL with the userinfo replaced; it never echoes the line, for the
same reason it refuses it. Put the credential where it belongs and probe the bare endpoint.
An unauthenticated `401` or `403` passes this check on purpose.

### `terragrunt-preflight-urls line <n> is not an http(s) URL`

One bare URL per line, `http://` or `https://`. A bare hostname is refused because curl would
guess a scheme and quietly probe something else. The line is named by index and not printed: a
value in the wrong input is the value most likely to be a secret pasted somewhere it does not
go.

### The log says `the saved plan for <stack> has gone stale`

State moved between the plan and the apply. The run re-plans and applies the newer plan rather
than refusing, and says so. `PLAN SOURCE:` in the log names which plan actually ran. If you need
the reviewed plan or nothing, re-run the whole job so plan and apply are adjacent again.

### A scheduled run finds nothing

Discovery maps changed files to stacks by path, and a change under `modules/` maps to nothing on
purpose: a module has no state of its own. Guessing which stacks use it is how a small module
tidy-up ends up planning the whole estate. `terragrunt-scope: all` plans everything.

### The check run says `No Terraform stacks affected` and the change was Terraform

Check where the changed file sits. A file inside a stack maps to that stack; a file above the
stacks maps to every stack beneath its own directory; a file under `modules/` or outside
`terragrunt-root` maps to nothing. [Which stacks a change
plans](setup.md#which-stacks-a-change-plans) is the whole table.

Until this was fixed, only the first of those worked: a shared `root.hcl` has no enclosing
stack, so it mapped to nothing and the run published `No Terraform stacks affected` as a
success. The pull request merged green with every stack that includes that root unplanned. If
you are pinned to a release from before the fix, that is what you are seeing, and
`terragrunt-scope: all` is the workaround.

### A shared root plans more stacks than you expected

Working as intended. Every stack beneath a shared `root.hcl` includes it through
`find_in_parent_folders`, so changing it changes all of them, and a file directly in
`terragrunt-root` reaches every stack in the estate. Move the change lower if it should not
have that reach, or split the root.

## `target: ansible`

### `Vault has nothing at '<path>' (404)`

On a KV v2 mount the read path carries a `/data/` segment that the UI path does not:
`secret/data/team/app`, not `secret/team/app`. That is the cause almost every time.

### `Vault refused the token for '<path>' (403)`

The token is valid and its policy doesn't grant read on that path. It needs read on the
paths you reference and nothing else.

### `Vault has '<path>' but no field '<field>' in it. Fields present: ...`

The reference is `<path>#<field>` and the field half doesn't exist. The message lists the
field names that do, never their values.

### `cannot reach Vault at <addr> (no response)`

From a private network this usually means the runner isn't on it. Check `runs-on` before
checking the address.

### `ansible-ssh-private-key and ansible-ssh-private-key-vault are both set`

Pick one. A literal secret and a Vault reference to the same thing is a mistake worth failing
on, rather than one silently winning.

### `the playbook is not idempotent: a second check-mode run still wants to change <n> task(s) on <hosts>`

The playbook applied cleanly and then, run again in check mode, still reported changes. That
means it doesn't converge. A zero exit only proves it ran.

Usual causes: a `command`/`shell` task with no `creates`/`changed_when`, or a template that
renders differently every run (a timestamp, an unsorted dict). Fix the task, or set
`ansible-verify-idempotence: false` if you accept the gap.

### `the playbook applied cleanly but could not be re-run in check mode`

A task with no check-mode support. Give it `check_mode: false`, or turn the verification off. The
fix is in the playbook, not in the deploy.

### `no playbook at <path>` / `no galaxy requirements file at <path>`

Paths are relative to `working-directory`. Both are checked before anything is installed.

### The playbook cannot see `VAULT_ADDR` or `VAULT_TOKEN`

By design. The action removes them from the environment before `ansible-playbook` starts, so a
token scoped to the fields Tremvok reads is not handed to every task, role and collection in
the play. Set `ansible-vault-passthrough: true` to pass them through deliberately. With
passthrough on and either `vault-addr` or `vault-token` missing, the run warns and passes
neither: half a credential fails inside a task, a long way from the cause.

### The playbook cannot see `SSH_PRIVATE_KEY` or `VAULT_PASSWORD` either

Also by design, and with no way to turn it off. Both are unset once their values are on disk
in `0600` files, which is what `--private-key` and `--vault-password-file` point at. A play
that wants the key or the vault password should take the file it is already given rather than
read the environment, and unlike a Vault token there is nothing a playbook can do with these
that the file does not already serve.

### `host-key checking is off for this run`

A warning, not an error. You didn't supply `ansible-ssh-known-hosts`. It's a real downgrade, so
it's said out loud rather than defaulted quietly. Supply the entries for anything reachable from
a network you don't control.

## The API

### `401` on `POST /v1/deployments`

`authorize()` is deny-by-default. The token failed one of: signature, issuer, audience, or the
owner allowlist. Check `TREMVOK_ALLOWED_OWNERS` is set (empty denies everyone) and that
`api-audience` on the action matches `TREMVOK_OIDC_AUDIENCE` on the function.

The action never fails a deploy because the record didn't land. A deploy that worked and a record
that didn't is a successful deploy.

### `GET /healthz` passes but writes fail

A health check proves the function imported. It proves nothing about the write path, the table,
or the IAM policy. Test with a real signed `POST`. The LocalStack smoke suite exists to make that
cheap.
