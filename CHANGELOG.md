# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`target: azure-apim-policy`**: publish a directory of policy documents (`api.xml` for the API
  scope, `<operation-id>.xml` per operation) into an Azure API Management API that already
  exists. All or nothing: API Management compiles a policy only when it is published, so the
  current policy at every scope is read first, and if any document is refused the scopes already
  replaced are put back (or cleared, where they had none). A document for an operation the API
  does not have is refused before anything is published, and a pull request publishes nothing.
  New inputs `apim-service-name`, `apim-resource-group`, `apim-api-id` and `apim-policy-format`
  (`rawxml` by default); the `azure-` sign-in inputs and `artifact-path` apply to it too. A new
  page, *Azure: a Function or API Management?*, says when to use it rather than
  `azure-functions-zip`.
- **Docs sites are agent-ready by default.** A step after the page metadata and the corpus
  (`scripts/gen_docs_agents.py`, on by default as `pages-agent-ready`) writes into the built
  site, for `github-pages` and `cloudflare-docs` alike:
  - **An Agent Skills index** at `/.well-known/agent-skills/index.json` (Discovery RFC v0.2.0)
    with one `SKILL.md` saying what the site covers, how to read it and how to cite it. It names
    `llms.txt`, `llms-full.txt` and the markdown twins only when the build wrote them, and the
    index carries the SHA-256 of the bytes written. The URL is path-absolute at the address the
    site is served from.
  - **WebMCP tools on every page** (`search_docs`, `read_page`, `list_pages`, `open_page`) from
    a same-origin, dependency-free script, `assets/javascripts/webmcp.js`: feature-detected on
    `document.modelContext` and `navigator.modelContext`, registered on load, and confined to
    the site. A `script-src 'self'` CSP admits it; without the API it does nothing.
  - **An `/auth.md`** for a site served at the root of its host, saying the docs need no
    credentials and pointing at the MCP server's own RFC 9728 metadata, so it stays true when a
    host routes `/auth.md` to an MCP Worker instead. A site mounted under a path gets none, and
    neither does one behind Access (`cloudflare-docs-require-access`).
  - **Configured by `extra.agents`** (`mcp`, `skill`, `webmcp`, `auth_md`), read from the
    resolved config like `extra.seo`. Whatever the site already publishes of these is kept, and
    a second run changes nothing.
  - **On `github-pages` the Pages artifact includes dot-directories** while the step is on:
    `actions/upload-pages-artifact` drops them by default, which would publish the site with no
    skills index and no error.
  - **The docs corpus step now runs before the Pages artifact is staged**, in the one block of
    steps that write into the site. It still runs for `cloudflare-docs` only.
- **The docs router serves the host's Agent Skills and WebMCP.**
  `/.well-known/agent-skills/index.json` lists a skill for the host, then every public site's
  skills from each site's own index, read over the service binding, re-addressed from the root
  and cached like the `llms.txt` summaries.
  Malformed entries are dropped, a name is listed once, and `PRIVATE_SITES` are never read. The
  landing page loads `/webmcp.js` (`list_docs_sites`, `search_docs` across every site's
  `llms.txt`, `read_page`, `open_site`), which its CSP already admits as `'self'`. Skills files
  are served with CORS. The script is a string, not a function's source: Wrangler bundles with
  esbuild's `keepNames`, whose `__name` helper does not exist in a browser, and
  `tests/test_workers_bindings.py` runs the bundled router's script to keep it that way.
- **[Agent readiness](docs/agent-readiness.md)** documents what a build writes, what the router
  adds, and what only a site's owner can do: DNS-AID records, markdown negotiation on a host of
  its own (a URL rewrite Transform Rule), and Workers routes for OAuth on a docs host.

- **Per-page search, social and agent metadata for both docs targets.** A step after the
  MkDocs build (`scripts/gen_docs_seo.py`, on by default as `pages-seo`) edits the built HTML
  in place, for `github-pages` and `cloudflare-docs` alike:
  - **A meta description per page.** Material prints `site_description` on every page with no
    `description:` of its own, which search engines read as duplicate metadata. Each such page
    now carries its first paragraph of prose, at most 155 characters and unique across the
    site; warnings, tables, code, lists, link-only lines and a sentence cut in half by a code
    block are passed over. The home page keeps `site_description`, and a home title that is
    only the site name gains its lead clause.
  - **Open Graph and Twitter tags, and one JSON-LD `@graph` per page**: `WebSite` and its
    publisher everywhere, `TechArticle` and a nav-built `BreadcrumbList` below the home page.
  - **A markdown twin of every page** at `<page>/index.md`, linked from the page with
    `rel="alternate" type="text/markdown"`, relative links resolved the way MkDocs resolves
    them for the HTML, and a `> Markdown source of <url>.` line under the title. `llms.txt`
    links the twins, as llmstxt.org asks; the search index keeps citing the pages.
  - **Configured by `extra.seo`** (locale, card image, publisher, author), read from the
    resolved config, so a shared `mkdocs.base.yml` sets it once through `INHERIT`. A step and
    not a plugin, for the reason the corpus is one.
  - **Nothing a page already has is replaced or doubled**: a description that is not the
    site's, Open Graph tags, Twitter tags, JSON-LD, a twin or its link. That keeps
    docs.calebsargeant.com's own hook in charge of its pages, and makes a second run a no-op.
  - A build that resolves no `site_url` is warned about, because MkDocs then writes no
    canonical links and an empty sitemap. On `cloudflare-docs` the router address stands in
    for the canonical link and `og:url`.
- **`docs.magmamoose.com/` is a front door, not a 404.** The docs router answers the host root
  itself: a landing page listing every site with its title and summary (canonical URL, Open
  Graph and Twitter cards, `CollectionPage`/`ItemList` JSON-LD, light and dark), `/llms.txt`
  indexing every site's own `llms.txt` and `llms-full.txt`, `/sitemap.xml` as a sitemap index,
  `/robots.txt` with `Content-Signal`, `Sitemap:` and `Agentmap:` lines, RFC 9116
  `/.well-known/security.txt` with an `Expires` computed per request, and `/favicon.ico`.
  - **Nothing is listed twice.** Which sites exist still comes only from the `[[services]]`
    blocks; what each is called comes from its own `llms.txt`, read over the service binding,
    cached per isolate for five minutes and capped at 24 reads a request, because one request
    may invoke at most 32 Workers. A site whose `llms.txt` cannot be read is listed by its
    repository name, not dropped.
  - **`PRIVATE_SITES` keeps an Access-gated site off the root once it is bound.** A service
    binding call never passes through Access, so describing a bound private site would copy
    its name and summary onto a public page. The private four are named before they are bound.
  - **Discovery for agents:** `/.well-known/ai-catalog.json` (AI Catalog) and
    `/.well-known/api-catalog` (RFC 9727) point at the docs MCP server's card, with CORS, an
    hour of caching and ETags that answer `If-None-Match` with a 304, and
    `/.well-known/mcp/server-card.json` redirects to the card. The landing page names them in
    a `Link` header.
  - **A page answers `Accept: text/markdown` with its `index.md` twin** when that is the first
    media range and the site publishes one, and falls back to the HTML page when it does not.
  - **Every response on the host carries HSTS, `nosniff`, `Referrer-Policy`,
    `X-Frame-Options` and `Permissions-Policy`**, the site Workers' included; the router's own
    pages add a strict CSP. `.txt` is served as `text/plain; charset=utf-8` and `.md` as
    `text/markdown; charset=utf-8`, so curly quotes in an `llms.txt` survive a client that
    does not assume UTF-8.
  - **A URL without its trailing slash works.** The site Worker's redirect to `/setup/` was
    relative to its own root, so `/tremvok/setup` landed on the host's 404; the router puts
    the `/<repo>` prefix back on a path-absolute `Location`.
  - **One spelling per path.** `/Tremvok/` or `/tremvok//setup/` is a 301 to the canonical
    path, so duplicate URLs stop serving and the path an Access application is written for is
    the only one that reaches a site.

- **Google Cloud credentials for `target: terragrunt`.** `gcp-workload-identity-provider`,
  `gcp-service-account` and `gcp-project-id` federate this run's GitHub OIDC token with a
  workload identity pool before the first plan. No service-account key is stored anywhere: the
  action writes the token and a small `external_account` credential configuration into
  `RUNNER_TEMP` at 0600 and exports `GOOGLE_APPLICATION_CREDENTIALS`, which the Terraform
  `google` provider and a GCS backend both read. A script rather than
  `google-github-actions/auth`, for the reason this repository runs neither
  `aws-actions/configure-aws-credentials` nor `azure/login`.
  - **Both halves are proved at login**, because they fail alike from inside Terraform and have
    different fixes: an STS exchange refused means the pool's issuer or attribute condition does
    not match this repository and ref; an impersonation refused means it does, and the
    `roles/iam.workloadIdentityUser` binding is missing.
  - A pool name passed where a provider resource name belongs is refused before any call.
  - **AWS needed nothing.** `aws-role-to-assume` has always applied to this target — the step is
    gated on the input rather than on a target — and the assumed-role session covers both the S3
    backend and the `aws` provider. A contract test now pins that for all three clouds, because
    the symptom of a login step regaining a target gate is not a missing input, it is a plan
    that dies inside a provider.

- **Azure credentials for `target: terragrunt`, and a check that says when they are missing.**
  `azure-client-id`, `azure-tenant-id` and `azure-subscription-id` now apply to the terragrunt
  target: the action signs in with this run's OIDC token before the first plan, so
  `provider "azurerm"` finds a session in its default chain. The step is gated on the input
  rather than on a target, like `aws-role-to-assume` already was.
  - **This is the provider's credential, not the state backend's.** `terragrunt-stack-env`
    supplies the backend's, which is why a run without this reads and writes state perfectly
    well and then dies at the plan with `could not configure AzureCli Authorizer: … Please
    run 'az login'`, once per stack, pointing at a `provider.tf` a `generate` block wrote.
  - **`terragrunt-credential-preflight`** (`auto` | `warn` | `off`, default `auto`) reads the
    `provider` blocks of every discovered stack and of every parent directory up to
    `terragrunt-root`, and fails before the first plan when a cloud they name has no
    credential on this runner. It knows azurerm/azuread/azapi, aws, google/google-beta and
    vcd; an unrecognised provider is passed over in silence. A provider block that configures
    its own authentication is not checked, which is the exemption that keeps it from being a
    check people switch off.
  - Run per stack with that stack's own environment, so a credential arriving through
    `terragrunt-stack-env` counts. It proves a credential is present, never that it works.
  - **Behaviour change for existing terragrunt callers**: a run whose providers have no
    credential now fails at the preflight instead of at the plan. It was going to fail either
    way; `warn` restores the old order if you need it.

- **The docs corpus, on `target: cloudflare-docs`.** The build writes `llms.txt` and
  `llms-full.txt` into the site before publishing it, and generates a search index of every
  page (`cloudflare-docs-index`, on by default, no credentials). With
  `cloudflare-docs-index-bucket` set, a deploy publishes that index to R2 as
  `index/<repo>.json`, the corpus the documentation MCP servers read (ADR-0005).
  - **Published after the site deployed, never before**, and never from a pull request: one
    key per repository, so a preview would overwrite the shared corpus with an unmerged branch.
  - **Citations use the router's address** (`https://<cloudflare-docs-host>/<path>/`) when a
    host is set, rather than `site_url`, so a stale `mkdocs.yml` cannot put a wrong link into
    every answer an agent gives.
  - **Not failure-isolated.** A deploy that silently failed to publish the index would be green
    while agents read the previous commit's documentation.
  - A build step rather than a MkDocs plugin: a repo that declares `plugins:` in its own
    `mkdocs.yml` silently discards every entry in the shared `mkdocs.base.yml`.

- **`target: cloudflare-docs`** — the same strict MkDocs build as `github-pages`, published to
  Cloudflare Workers Static Assets. The canonical address becomes `https://<host>/<repo>/`,
  and one hostname serves every repository by path. Implements the hosting half of
  [ADR-0005](https://github.com/MagmaMoose/nievah/blob/main/docs/adr/0005-docs-sites-and-mcp-surfaces.md);
  the local decision record is `.claude/decisions/0004-docs-on-workers-static-assets.md`.
  - **Dispatch is over a service binding, never an HTTP proxy.** A proxy needs a public origin
    hostname per site, which `workers_dev = false` exists to prevent, and proxying an
    Access-gated origin moves the gate off the user and onto the router.
  - **One job, not two.** The `github-pages` shape needs a second job only because
    `actions/deploy-pages` requires `pages: write` and the `github-pages` environment, which a
    composite action cannot declare. Wrangler requires neither.
  - **A pull request publishes nothing.** These Workers carry no route and no workers.dev URL,
    so there is no address a preview could be served from. The strict build is the check.
  - **An empty site directory is refused**, because publishing nothing over a site that is
    currently serving succeeds.
  - New inputs: `cloudflare-docs-host`, `cloudflare-docs-path` (defaults to the repository
    name), `cloudflare-docs-require-access`. The `pages-` build inputs and the `cloudflare-`
    credential inputs are now shared with this target.

- **`cloudflare-docs-require-access`** — refuse to publish unless a Cloudflare Access
  application actually covers `<cloudflare-docs-host>/<cloudflare-docs-path>`. This restores
  the `require-access` enforcement removed in `83ebc48` and deferred by ADR-0003.
  - Its three outcomes are never collapsed: covered, not covered, and **could not tell**. A
    403 from a token lacking `Access: Apps` read looks very like an account with no
    applications, and reading the first as the second publishes a private site to the open
    internet while reporting that it checked.
  - Needs the `Access: Apps` READ permission, which Cloudflare's "Edit Cloudflare Workers"
    token template does not include. The failure message says so.

- **CI verifies every Wrangler binding with `wrangler deploy --dry-run`.** A binding is only
  real if Wrangler prints it: the rate-limit block takes `name` where every other binding takes
  `binding`, and a config that gets it wrong deploys a Worker that throws on its first request.
  The check fails rather than skips when Node is absent, so it cannot become a required check
  that never reports.

- **The docs router is deployed by CI** (`.github/workflows/docs-router.yml`), and its routing
  table covers the fleet rather than the four repositories it was sketched with. Adding a
  repository's docs to `docs.magmamoose.com` is adding a `[[services]]` block and redeploying,
  and a redeploy nothing performs is a path that 404s with a green build everywhere.
  - **A binding to a Worker that has not published yet fails the whole deploy**, with
    `Service binding '<NAME>' references Worker '<service>' which was not found [code: 10143]`.
    It is not degraded to a dead route, so the table can never run ahead of the site Workers.
    That is the opposite of a missing binding, which 404s quietly.
  - caldrith, dunmir, nievah and noctyr are deliberately absent until their Access
    applications exist and they have published once; `cloudflare-docs-require-access` refuses
    their deploy until then.
  - A pull request is a dry run, never a preview: `--preview-alias` needs a workers.dev
    subdomain and `workers_dev = false` is what the service-binding design rests on.

- **`cloudflare-verify-config`** (on by default): before any `cloudflare-workers` publish, run
  `wrangler deploy --dry-run` and refuse to publish when Wrangler reports configuration it will
  not apply. A misspelled `[[r2_bucket]]` is only an "Unexpected fields" warning, Wrangler exits
  0, and the Worker deploys with no bucket; a top-level binding an `--env` deploy does not
  inherit is also only a warning. Verified against Wrangler 4.114.0 and 4.127.1. Costs one extra
  bundle per run.

### Changed

- **The docs router can send `/` to a documentation hub kept elsewhere.** With
  `LANDING_REDIRECT` set to an `https` URL in its `wrangler.toml`, `docs.magmamoose.com/`
  answers a `302` there instead of serving the landing page, for every client except one whose
  first media range is `text/markdown`, which still gets the `llms.txt` index. The redirect
  keeps the discovery `Link` header, with absolute targets so a client carrying it across the
  hop cannot resolve them against the other host, and reads no site's `llms.txt`. Blank or not
  an `https` URL, and the landing page is served as before. It ships blank, to be set to
  `https://www.magmamoose.com/documentation/` once that page is live (MagmaMoose/website#82).
- **`cloudflare-docs-require-access` is checked only when a publish is actually going to
  happen.** It was gated on the target alone, so it also ran in `preview` mode — on a pull
  request, which for this target publishes nothing at all. In a repository that sets it, every
  documentation pull request therefore failed on a deploy it was never going to do. A required
  check that is always red is one people learn to merge past, which costs more than the early
  warning is worth. `github-pages` never had this because v1's caller passed `target: none` on
  a pull request and every target-gated step fell away with it; `mode` replaced that and this
  step did not get the memo.

- **`dry-run` on `cloudflare-workers` now runs Wrangler's own `wrangler deploy --dry-run`**
  instead of logging the command. It bundles and validates the Worker, uploads nothing, and
  calls no API, so it no longer requires `cloudflare-api-token` or `cloudflare-account-id`. A
  dry run that does not bundle now fails the job. This makes a pull request validatable without
  a preview upload, which matters for a Worker whose bindings reach private data.

- **`verify-method`** — the HTTP method `verify-url` is requested with, `GET` by default.
  A GET cannot verify a POST-only endpoint at all: a webhook receiver binds POST and nothing
  else, so a GET reaches no function and the platform answers 404 — which is also what a
  package containing no functions returns, leaving the check unable to tell a working deploy
  from a broken one. `verify-method: POST` with `verify-status: 401` asserts instead that the
  function is bound and that its signature check refuses an unsigned request. The method
  survives a redirect (`--post301/302/303`), because curl otherwise downgrades a redirected
  POST to a GET and quietly changes the assertion.

- **`target: azure-functions-zip`** — publish a zip to an Azure Function App and prove the app
  serves it. Signs in with `azure-client-id`/`azure-tenant-id`/`azure-subscription-id` over
  this run's GitHub OIDC token against an Entra ID federated credential, so no publish profile
  is stored anywhere, then deploys with `az functionapp deployment source config-zip` and
  polls the app until it answers.
  - The CLI's exit code is **not** treated as the outcome. `config-zip` prints
    `Operation returned an invalid status 'Bad Request'` and exits non-zero over deploys that
    succeeded, so a non-zero exit is corroborated against `WEBSITE_RUN_FROM_PACKAGE` and only
    then called a failure.
  - Platform state is not treated as evidence either: a Function App reports `state: Running`
    and `availabilityState: Normal` while returning 503. An HTTP answer from the app is what
    ends the run, and a first deploy retries through the 503 a freshly created Consumption app
    returns until content is first published.
  - A package whose `functions.metadata` and `.azurefunctions/` are not at the archive root is
    refused, because that package deploys cleanly and then 404s on every route.
  - A pull request publishes nothing unless `functions-slot` is set: a Linux Consumption plan
    has no deployment slots, so there is no destination that does not take production traffic.

### Fixed

- **A large Terragrunt plan comment was never posted.** `notify-pr.sh` handed the whole request
  to `curl` as one argument, and a plan across many stacks is past the kernel's 128 KiB cap on a
  single argument once JSON-escaped: the post died with `Argument list too long` and the run said
  only "could not post the pull-request comment". The request now reaches `curl` as a file and
  the body reaches `jq` on stdin. The two write calls also pass `--fail`, so a post GitHub
  refuses is a warning rather than a logged success.
- **The plan comment fits GitHub's 65,536-character limit.** Excerpts share `COMMENT_BUDGET`
  (60,000 bytes) once the table and the apply section have taken theirs, and below 400 bytes each
  they are left out for a pointer to the run. A stack with no changes gets its table row and no
  excerpt, and terminal colour codes are stripped before an excerpt is measured. `notify-pr.sh`
  cuts any other body that is still too long, and says so in the comment.

## [2.0.0]

Released as v1.0.26 and retagged: the breaking changes below are v2, and were only ever
called v1.x because the release pipeline could not see them.

### Fixed — the floating major tag

- **`v1` no longer floats onto a breaking release.** `GitVersion.yml` teaches GitVersion
  to read Conventional Commits, so a `feat!:` subject or a `BREAKING CHANGE:` footer bumps
  the major and `feat:` bumps the minor. Until now GitVersion ran on its built-in defaults,
  which only understand `+semver:` tokens: every release since v1.0.0 was a patch,
  including the two that deleted the reusable workflows and renamed every docs input. The
  release job then force-moved `v1` onto them, and nine repositories pinned to `@v1` were
  handed the v2 contract without a version change to warn them.

### Changed — BREAKING (v2)

- **The `docs` target is now `github-pages`,** and its inputs are prefixed `pages-` rather
  than `docs-` (`docs-toolchain` → `pages-toolchain`, and so on). The target is named for
  where it publishes, like every other target.
- **`docs-target` is removed.** Once the target *is* `github-pages` its only other value was
  `none`, and GitHub Pages has no preview destination: there is one site, and publishing to
  it is publishing. A pull request (`mode: preview`) or a `dry-run` now builds and checks
  without staging an artifact, which is what those already mean everywhere else.

- **One action, six targets.** `target` is now the deployment target
  (`github-pages` · `s3-cloudfront` · `lambda-zip` · `terragrunt` · `ansible` ·
  `cloudflare-workers`) and is the only required input. At v1 `target` meant the docs
  destination. Full table in [docs/migration.md](docs/migration.md). **`@v1` is frozen at
  v1.0.18 and keeps working** — it was briefly not, see *Fixed* below.
- **The `deploy/` entry point is gone.** `MagmaMoose/tremvok/deploy@v1` no longer exists; its
  three targets are targets on the root action, with `aws-`, `s3-`, `cloudfront-` and
  `lambda-` prefixes on its inputs. Its scripts moved from `deploy/scripts/` to `scripts/`.
- **The reusable workflows are gone.** `.github/workflows/docs.yml` and
  `docs-github-pages.yml` are removed: one action is the whole product, and a second callable
  surface for one target was a place for the two to disagree. The Pages deploy job they
  carried is ten lines in the caller's own workflow — `examples/github-pages.yml`.
- **An inapplicable input now fails the run.** `validate-inputs.sh` checks every input
  against the selected target before the checkout and reports every mistake at once. At v1
  an undeclared input was a warning nothing acted on.
- **A plan-only Terragrunt run reports success**, not failure. It deployed nothing on
  purpose; the notification used to call that a failed deploy.
- `mode: auto` now resolves `schedule` and `pull_request_review`, which it used to refuse —
  breaking the Terragrunt drift run on its own cron.

- **A standing approval no longer applies on a plain `pull_request` run.** Under
  `terragrunt-apply: auto` the apply now needs an event that authorises it: a
  `pull_request_review` whose review is an approval, or the merged-push path with
  `terragrunt-apply-on-merge` on. Reading an approval the run merely found standing is no
  longer enough.

  The sequence this prevents: a reviewer approves commit A, the author pushes commit B, and
  the `pull_request` run for B reads the same approval and applies B. Nobody reviewed B. It
  is only safe where branch protection dismisses stale reviews on push, which the action can
  neither see nor require, so the guard is in the action.

  This is a behaviour change for existing callers and it ships rather than hiding behind an
  input, because an input defaulting to the unsafe answer is the same defect with a knob on
  it. What changes in practice: a run that used to apply now plans, comments and publishes
  the check as `action_required` with the title `Approved, but not applied for this commit`.
  If you relied on the old behaviour, add
  `pull_request_review: { types: [submitted, dismissed] }` to your triggers, which is what
  `docs/setup.md` has always shown, and re-approving applies the commit in front of you. For
  a one-off, `terragrunt-apply: force` applies by hand for an actor named in
  `terragrunt-apply-operators`. Two smaller consequences of the same rule: a run triggered by
  a COMMENTED or CHANGES_REQUESTED review plans rather than spending an older approval, and a
  `workflow_dispatch` that names a pull request with `terragrunt-pull-request` plans it,
  since dispatching a workflow is not approving a commit.

### Added

- **`build-git-credentials`** (default empty, so nothing changes for an existing caller): the
  two targets that run a build, `github-pages` and `cloudflare-workers`, can now fetch a
  dependency from a private git host. One `<host> <username>:<token>` per line, and the
  username is written out rather than assumed because the forges disagree about it
  (`x-access-token` for a GitHub App token, `oauth2` for a GitLab one). The line is split at
  the FIRST `:`, which is the safe way round: the username is the half that cannot contain
  one, so a token that does survives intact.

  Each line becomes one `url.<credentialled>.insteadOf` rewrite carried in `GIT_CONFIG_COUNT`
  / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` for the rest of the job, so a requirements file
  keeps pinning the plain URL and stays reviewable. Never `git config --global`: a self-hosted
  runner is a shared, long-lived machine, and a global rewrite would leave the token in
  `~/.gitconfig` for whatever runs there next. An existing `GIT_CONFIG_COUNT` is extended
  rather than overwritten, and the count is written last, so a line refused halfway through
  leaves the configuration the job already had exactly as it was.

  Every token is registered with `::add-mask::` on receipt, before any check can fail, and no
  message ever carries one: a malformed line is named by its index and its host, and the host
  is only quoted when it looks like a host — a bare token pasted onto a line would otherwise
  be printed into an annotation as public as the repository. A token under eight characters is
  refused rather than masked, because masking a string that short replaces every occurrence of
  it in every later line of the log. `scripts/build-git-credentials.sh`,
  `tests/bats/build_git_credentials.bats`.

- **`terragrunt-apply-on-merge`** (default `false`): a push to the default branch can now
  apply what was merged. **The default is unchanged for existing callers.** With it off, which
  is what you get on upgrade, a push plans exactly as it always has: no commit-to-pull-request
  lookup, no approval read, nothing applied. Turning it on is the decision to let a merge
  apply.

  A push event carries no pull request, and the approval that authorises the apply belongs to
  the pull request the commit was merged from, so with this on the run resolves it from the
  commit (`scripts/resolve-merged-pr.sh`, `GET /repos/{repo}/commits/{sha}/pulls`) and feeds it
  to the existing approval gate. Which pull request wins is stated rather than inherited from
  the API's ordering: one whose `base.ref` is the pushed branch, else the oldest `merged_at`.
  Three outcomes stay distinct: merged with an independent approval applies; merged without
  one, or pushed directly, plans and reports with a `neutral` check run rather than failing,
  because an unapproved merge is a branch-protection matter; and an API that cannot be read
  fails the run *after* the check run and the step outputs are published, because an outage
  must never read as "nobody approved" and a required check that never reports blocks a pull
  request for ever. (Not after the plan comment: an unreadable lookup is the case where there
  is no thread to comment on, which is why the failure is reported on the check run.) Neither
  refusal fires on a merge whose stacks all plan clean — an unreadable review list and an
  unreadable lookup are guarded the same way, because refusing to apply nothing is not a
  refusal and a transient API blip should not turn the default branch red while the same run
  reports "No changes to apply". Both still warn, so a token missing `pull-requests: read`
  is visible rather than silent. The plan comment on the merged pull request is rewritten
  in place to the apply result instead of being left on "applying now".

  It is a separate input from `terragrunt-apply` on purpose: that one answers "who may
  authorise an apply?", this one answers "should a merge commit apply at all?". The path needs
  `pull-requests: read`, which the `pull-requests: write` the docs already ask for covers.

- **With `terragrunt-apply-on-merge` on**, a run with pending changes and no open pull request
  (a merge, a direct push, or the scheduled drift run) publishes a `neutral` check run rather
  than `action_required`: that check lands on a commit already on the branch, where there is no
  merge left to block, and turning the default branch red is not what fixes an unapproved
  merge. **With the input off, which is the default, the conclusion is `action_required`
  exactly as before.** It is the better answer either way, but it is still a different
  conclusion from the one a caller sees today and somebody may be watching for it on a drift
  cron, so it arrives with the input rather than with the tag.

- **`terragrunt-preflight-urls`**: URLs probed once each, with an 8-second timeout, before the
  first plan. Terragrunt buffers plan output to a file, so a state backend or provider API the
  runner cannot reach is a silent wait until `terragrunt-timeout` rather than an error. Any
  HTTP answer passes, `401` and `403` included, because an unauthenticated probe of a
  credentialed endpoint is supposed to be refused; only a curl code of `000` fails, and a `5xx`
  warns and passes so a transient `503` cannot make this a flake. The runner's egress IP is
  printed on the failure path only. Empty (the default) probes nothing, so nothing changes for
  existing callers. This proves reachability, not authorisation. Nothing from this input is
  echoed raw: a refusal names the line by index and shows the URL with any userinfo replaced,
  because a guard that refuses a credential-bearing URL by printing the credential is worse
  than no guard.

- **`terragrunt-pull-request`**: act on a named pull request instead of the one in the event
  payload, for a manual run. One override drives all three consumers: the approval gate reads
  that pull request's reviews, the plan comment goes to its thread, and the check run is
  published against its head commit, fetched from the API because a dispatch event carries no
  pull request. Digits only, checked in the action's first step before the checkout, the tool
  install and the assume-role. A fork pull request is refused, as the automatic path already
  refuses fork code. `terragrunt-scope: auto` now means "the stacks that pull request touches"
  whenever a pull request is in scope, however it got there. Checking out
  `refs/pull/<n>/merge` stays the caller's `actions/checkout` config; the run warns, and never
  fails, when the tree does not contain the named head commit.

- **`ansible-vault-passthrough`** (default `false`): hand `VAULT_ADDR`, `VAULT_TOKEN` and
  `VAULT_NAMESPACE` to the `ansible-playbook` process, so a playbook can read its own secrets
  from the same HashiCorp Vault rather than having them copied into a second store that stops
  being rotated. Off by default, and the default now **removes** them from the playbook's
  environment: they were inherited by accident, and widening a credential's blast radius should
  be a decision. Needs both `vault-addr` and `vault-token`; with only one, nothing is passed and
  the run says so.

  The default has to be the one that unsets, and this was argued the other way. Defaulting to
  `true` would make the input a no-op with a name that claims otherwise, and the option to turn
  passthrough *off* would be the thing nobody knew to reach for. The `vault-*` inputs shipped
  one day before this, so the window in which anything can depend on the accidental inheritance
  is a day wide.

- **The playbook no longer inherits the SSH private key or the ansible-vault password
  either.** Same argument, applied to the rest of the credentials rather than a third of them:
  `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `VAULT_PASSWORD` and their `*_VAULT` partners reach the
  step as environment variables, and every child process inherits them, so a role or collection
  in the play could read the two most sensitive values this target handles. They are unset once
  their values are on disk at `0600`, which is what the `--private-key` and
  `--vault-password-file` flags point at, so the run itself needs nothing from the variables.
  There is no opt-out and no passthrough input for these: unlike a Vault token, they have no
  use inside a playbook that the file does not already serve.

- **Ansible secrets can be read from HashiCorp Vault.** `vault-addr` + `vault-token`, then
  name a secret by `<path>#<field>` with `ansible-ssh-private-key-vault`,
  `ansible-ssh-known-hosts-vault` or `ansible-vault-password-vault`. Copying a secret that
  already lives in Vault into a GitHub secret means rotating it in Vault silently stops
  rotating the copy; this removes the copy. Each `-vault` input is the alternative to its
  literal, never a supplement, and setting both fails. KV v1 and v2 both work without the
  caller declaring which. The value is masked and written to a `0600` file on the same single
  path a literal takes, and a failed read fails the run rather than proceeding with no key,
  which would surface as an SSH auth error a long way from the cause.

- **`terragrunt-stack-env`**: environment applied per stack, one `<glob> KEY=VALUE` per line,
  first match wins. For an estate whose production Terraform state lives in a separate
  storage account from the rest: one credential cannot reach both, so without this the only
  options are a job per credential class or a pipeline that fails on the first stack of the
  other kind. Values are passed with `env` rather than exported, so one stack's credential
  never reaches the next stack's run, and the apply gets the same environment the plan got.

- **`target: cloudflare-workers`** — deploy a Worker and its static assets with Wrangler.
  `mode: deploy` runs `wrangler deploy`; `mode: preview` runs
  `wrangler versions upload --preview-alias pr-<N>`, which uploads a version reachable on its
  own URL that takes **no production traffic**, so a pull request cannot land on the live
  routes. Supports assets-only Workers (no entry point, files served straight from the edge)
  and Workers that run code, via `cloudflare-main` and `cloudflare-build-command`. The
  Wrangler config stays authoritative for asset directory, routes, custom domains and 404
  handling; the inputs are overrides for what a workflow legitimately varies. Wrangler and
  Node versions are pinned, because the tool that publishes to production is not a floating
  dependency. Reverses the Cloudflare half of ADR 0001, see
  `.claude/decisions/0003-cloudflare-workers-target.md`.

- **`target: ansible`** — pinned Ansible and galaxy requirements, a playbook run over SSH,
  and an idempotence proof: after a real run the playbook runs again in check mode and the
  run fails if anything would still change. A zero exit only proves it ran. SSH keys and
  vault passwords are masked on receipt, written to `0600` files under `$RUNNER_TEMP`, never
  passed on a command line, and removed by a trap however the step exits. Check mode is the
  default on a pull request.
- **Terragrunt applies the saved plan.** `plan -out` writes it, `apply` applies that file, so
  what lands is the diff that was reviewed. A plan that has gone stale is re-planned with a
  warning rather than refused, and `PLAN SOURCE:` in the log names which one ran.
- **Pinned, checksum-verified tofu and terragrunt** (`terragrunt-bootstrap.sh`), cached per
  version pair on the runner, with a shared provider plugin cache. The binary that applies to
  production is no longer whatever the runner happened to have.
- Terragrunt gained `terragrunt-exclude`, `terragrunt-apply-operators` (who may force an
  apply; empty means nobody), `terragrunt-refresh` (skip the provider refresh on a pull
  request), `terragrunt-timeout` and `terragrunt-log-level`.
- **`scripts/lib/input-targets.json`**, generated from `action.yml` by
  `scripts/gen_input_targets.py`, is the single source for which inputs apply to which
  target — read by the runtime validator and by the generated reference, so the check and
  the documentation cannot disagree. CI fails on drift.
- `docs/migration.md`, and per-target permission blocks in the generated action reference.

### Fixed

- The three `examples/` workflows called `MagmaMoose/tremvok@v1` with AWS inputs the root
  action did not declare, so they built an MkDocs site instead of deploying. They now match
  the action they call — which is a large part of why the surfaces merged.
- `preflight.sh` no longer skips `docs` and `ansible` runs for want of an AWS credential
  neither target uses.
- **`preflight.sh` no longer skips the `terragrunt` target for want of an AWS credential**,
  which made the whole target a no-op on any estate that is not on AWS: every terragrunt step
  in `action.yml` is gated on that skip. Terragrunt is provider-agnostic, and its credentials
  come from the backend and provider blocks in the caller's own configuration, which may be
  AWS, Azure, GCP, a private cloud, or several in one run. `terragrunt-stack-env` exists to
  carry exactly those. The requirement now covers `s3-cloudfront` and `lambda-zip` alone, the
  two targets that call AWS themselves. A terragrunt run that genuinely needed AWS now fails
  in the provider, with a message naming the provider, which is the better of the two errors.
- **A change to a shared `root.hcl` or any other file above the stacks now maps to the stacks
  beneath it.** `terragrunt-discover.sh` walked up from a changed path to its nearest
  enclosing stack and stopped, so a file that sits ABOVE every stack had no enclosing stack
  and mapped to nothing: the run reported zero stacks and published the check as SUCCESS with
  "No Terraform stacks affected", and the pull request merged green with nothing planned and
  nothing applied. A changed path inside `terragrunt-root` with no enclosing stack now maps to
  the stacks beneath the nearest of its ancestors that holds any, so a shared root affects
  every stack that includes it through `find_in_parent_folders`, and a path directly in
  `terragrunt-root` affects every stack there is. A file that IS inside a stack still maps to
  that one stack, which is narrower and already right.

  **This reverses the rule that a change under `modules/` maps to nothing.** That rule was
  argued on the grounds that guessing which stacks use a module from its path is how a module
  tidy-up plans the whole estate, and that the scheduled drift run covers what is missed. What
  it did in practice was publish SUCCESS with "No Terraform stacks affected" for a real change
  to shared logic, merge green, and apply nothing. The two errors are not symmetric: planning
  is read-only and an apply only applies what its plan found, so a module edit that changes no
  stack produces an empty diff and costs wall-clock, while the narrow answer costs
  correctness. A module usually lives in a directory the exclude list keeps out of the stack
  list, so no stack sits beneath it and only walking up reaches them. It stays bounded by
  stopping at the first ancestor that holds stacks, so a separate estate under the same root
  is untouched.
- `terragrunt-bootstrap.sh`'s checksum lookup runs with `|| true`: with `pipefail` on, a
  `grep` that matched nothing made the assignment non-zero and `set -e` exited the script
  silently, exactly where the loudest possible failure is wanted.
- **A malformed `terragrunt-stack-env` line no longer prints its VALUE.** The refusal
  interpolated the whole line into its `::error::` annotation, and that input exists to carry
  per-stack state-backend credentials, so a typo in a line holding a storage-account key
  published the key to a log as public as the repository. The message now names the line
  index, the glob and the KEY, and nothing at or after the first `=` — including when the glob
  itself was forgotten and the assignment landed in the glob slot.

### Added (previously unreleased, carried into v2)

- **Post-deploy verification** (`verify-url`, `verify-header`, `verify-header-match`) with
  retries, catching the deploy that uploaded but did not bind.
- **Notifications**: sticky pull-request comment, Slack and Microsoft Teams incoming webhooks,
  each optional and failure-isolated.
- **OIDC role assumption** (`assume-role.sh`), so no repository stores an AWS key.
- **Honest skips** for fork pull requests and repositories with no credential configured.
- **The Tremvok API** (`src/tremvok/`): FastAPI + Mangum on Lambda, recording deployment
  history in DynamoDB and fanning notifications out. Authenticated by GitHub Actions OIDC with
  a deny-by-default owner allowlist; the `repository` a record lands under is the token's claim.
- **RS256 verification with no crypto dependency** (`oidc.py`), keeping the Lambda package
  small and architecture-portable, with an optional pinned JWKS in Parameter Store for
  egress-restricted or Enterprise Server deployments.
- **Terraform module** (`terraform/modules/tremvok-api`) capped three independent ways —
  API Gateway throttle, Lambda reserved concurrency, provisioned DynamoDB — because AWS has no
  spend cap.
- **LocalStack harness** (`make -C terraform dev`) proving the whole stack without an AWS
  account.
- Tests: 188 `bats` cases over the shell scripts, 181 `pytest` cases over the API, the
  action contract and the applicability map, and an end-to-end smoke suite against LocalStack.

### Fixed

- **`lint-docs` classified a licence by pattern order, not by where it appears in the
  file.** A `LICENSE` opening "Proprietary License" that excepts one directory under
  Apache-2.0 was reported as Apache-2.0, so a correct README saying "Proprietary" failed
  with `claims Proprietary but LICENSE is Apache-2.0`. It took a consuming repository's
  docs site offline for three days over a licence claim that was right. The operative
  licence is now the one that appears FIRST in the file, since a licence states its own
  terms before its carve-outs.

[Unreleased]: https://github.com/MagmaMoose/tremvok/compare/v2.0.0...main
[2.0.0]: https://github.com/MagmaMoose/tremvok/releases/tag/v2.0.0
