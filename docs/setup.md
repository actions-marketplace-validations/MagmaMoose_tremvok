# Setting Tremvok up

<!-- sources: action.yml, README.md -->

Pick a target, add the job, grant the permissions that target needs. The
[action reference](action-reference.md) has every input and the exact permission block per
target; this page is the task-shaped version.

## The workflow, per target

### `github-pages`

`actions/deploy-pages` requires `pages: write` and the `github-pages` environment, and a
composite action can declare neither. So the action builds and stages the artifact, and a job
of yours publishes it. The environment name is fixed. GitHub creates `github-pages` when you
set the Pages source to "GitHub Actions", and `deploy-pages` expects that name, so this job
is boilerplate, not a decision:

```yaml
permissions: { contents: read }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/tremvok@v2
        with:
          target: github-pages
          pages-strict: true

  deploy:
    needs: build
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions: { pages: write, id-token: write }
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v5
```

There's nothing to set for a pull request. GitHub Pages has one site and no preview
destination, so publishing to it is publishing, and a pull request (which resolves to
`mode: preview`) builds and checks without staging an artifact. A dry run does the same. The
build is the check, and it can't publish by accident.

Set **Settings → Pages → Source = "GitHub Actions"** once per repository.

#### Search, social and agent metadata

Both docs targets finish the build by giving every page the metadata MkDocs Material leaves
out. The step edits the built HTML, is on by default (`pages-seo`), and needs no credentials
and no network:

- **Its own meta description.** Material prints `site_description` on every page without a
  `description:` in its front matter, so a search engine sees one sentence repeated across
  the site. Each of those pages gets its first paragraph of prose instead, at most 155
  characters and unique across the site. Warnings, tables, code, lists and lines that are
  only links are skipped. The home page keeps `site_description`, and when its title is the
  bare site name, the lead clause of `site_description` joins it
  (`Tremvok - One GitHub Action for the whole deploy side`).
- **Open Graph and Twitter tags**, so a link pasted into Slack or LinkedIn unfurls as a card.
- **A JSON-LD graph**: the `WebSite` and its publisher on every page, and a `TechArticle`
  and a `BreadcrumbList` built from the nav on every page but the home page.
- **A markdown twin**: the page's source at `<page>/index.md` (the llmstxt.org convention),
  announced with `<link rel="alternate" type="text/markdown">`, its relative links resolved
  the way MkDocs resolves them for the HTML so they still work from where the twin lives.
  On `cloudflare-docs`, `llms.txt` links the twins.

Configure it under `extra.seo` in `mkdocs.yml`. `extra` is a dict, so it merges through
`INHERIT` and a shared base can set it once for every site. Every key is optional:

```yaml
extra:
  seo:
    locale: en_GB                  # og:locale, and inLanguage (en-GB) in the JSON-LD
    image:                         # the link-preview card
      url: https://www.example.com/og/card.png
      width: 1200
      height: 630
      alt: Example docs            # defaults to site_name
    publisher:                     # use the @id your own site's JSON-LD already has
      type: Organization
      id: https://www.example.com/#organization
      name: Example
      url: https://www.example.com/
      logo: https://www.example.com/logo.png
      same_as: [https://github.com/example]
    # author: the same shape; defaults to the publisher, then to site_author
    # twitter: "@handle"
```

A page keeps whatever it already has: a description that is not `site_description` (from
front matter or a hook of your own), Open Graph tags once `og:title` is present, Twitter
tags once `twitter:card` is, JSON-LD once any `application/ld+json` block is, and a twin or
twin link that exists already. The same rules make a second run change nothing.

Canonical links, `og:url` and the JSON-LD need an absolute address, which is `site_url`. On
`cloudflare-docs` the router address stands in when `site_url` is unset, and the step warns,
because MkDocs has then written no canonical links and an empty `sitemap.xml`.

#### Agent readiness

A step after the metadata makes the site usable by AI agents, on by default
(`pages-agent-ready`) and configured under `extra.agents`: an Agent Skills index at
`/.well-known/agent-skills/index.json` with a skill that says what the site covers and how to
read and cite it, WebMCP tools on every page (search, read a page as markdown, list and open
pages), and an `/auth.md` for a site served at the root of its host. [Agent
readiness](agent-readiness.md) has the details, and the steps a build cannot take for you: DNS
records, markdown negotiation on a host of your own, and OAuth for an MCP server.

#### Installing a dependency from a private git repository

A docs build often pins its theme straight to a private repository:

```text
mkdocs-yourtheme @ git+https://git.example.invalid/your-org/theme.git@v1.1.2#subdirectory=theme
```

That clone is git's own, several processes below the action, so there is no flag to pass a
token on. `build-git-credentials` leaves one where git will find it, one
`<host> <username>:<token>` per line:

```yaml
      - uses: MagmaMoose/tremvok@v2
        with:
          target: github-pages
          build-git-credentials: |
            git.example.invalid  x-access-token:${{ steps.app-token.outputs.token }}
```

Each line becomes a `url.<credentialled>.insteadOf` rewrite carried in `GIT_CONFIG_COUNT` /
`GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`, which live in the job's environment and end with
the job. Requirements files keep pinning the plain URL, so they stay reviewable. Don't reach
for `git config --global` in a step of your own instead: a self-hosted runner is a shared,
long-lived machine, and a global rewrite leaves the token in `~/.gitconfig` for whatever runs
there next.

Write the username out, because the forges disagree about it: `x-access-token` goes with a
GitHub App installation token, `oauth2` with a GitLab one. Prefer a short-lived App token
(`actions/create-github-app-token`) over a personal access token — it expires within the hour
and it only reaches the repositories the installation was given.

`cloudflare-workers` takes the same input for the same reason: its build runs on the runner
too.

Every token is masked the moment it is read, and none is ever echoed. A line the action
refuses is named by its index and its host, and the host is only quoted when it looks like
one, because a bare token pasted onto a line would otherwise be printed into an annotation as
public as the repository.

### `cloudflare-docs`

The same strict MkDocs build as `github-pages`, published to Cloudflare Workers Static Assets
instead of GitHub Pages. The canonical address is `https://<host>/<repo>/`, and one hostname
serves every repository by path:

```yaml
permissions: { contents: read, pull-requests: write }

jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: MagmaMoose/tremvok@v2
        with:
          target: cloudflare-docs
          cloudflare-docs-host: docs.magmamoose.com
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

One job, where `github-pages` needs two. That second job exists only because
`actions/deploy-pages` requires `pages: write` and the `github-pages` environment, which a
composite action cannot declare. Wrangler requires neither.

Three things have to exist before the first run:

1. **`site_url` is the canonical address.** Set it to `https://<host>/<repo>/`. MkDocs emits
   `<link rel="canonical">` and its sitemap from it, so leaving it pointed at the old host
   publishes absolute links to somewhere that is no longer the address.
2. **A `wrangler.toml` at your repository root.** Copy `workers/docs-site/wrangler.toml` and
   set `name` to `docs-<repo>`. It declares `[assets]` and, deliberately, no route and no
   `workers_dev` URL.
3. **A `[[services]]` block in the router's config**, binding `<REPO>` to `docs-<repo>`.
   Without it the router 404s your path — a quiet omission, since your own build stays green.

A pull request publishes nothing. These Workers carry no route and `workers_dev = false`, so
there is no disposable address a preview could be served from; the strict build is the check.
That is the same position `github-pages` is in, arrived at differently.

#### Why the router uses a service binding

The site Workers are unreachable over HTTP. The router on `<host>` calls them through a
**service binding**, which is an in-process dispatch on Cloudflare's network rather than a
request on the wire. An HTTP proxy would need a public origin hostname for each site —
exactly what `workers_dev = false` exists to prevent — and proxying an Access-gated origin
would need the router to hold a service token, at which point Access is gating the router
rather than the person visiting.

#### What the router serves itself

The host root is the router's own, so the fleet has one front door for people, crawlers and
agents:

| Path | What it is |
|---|---|
| `/` | A landing page listing every site, with its title and summary, or a `302` to your own documentation hub (below) |
| `/llms.txt` | An [llms.txt](https://llmstxt.org/) index linking each site's `llms.txt` and `llms-full.txt` |
| `/sitemap.xml` | A sitemap index of every site's `sitemap.xml` |
| `/robots.txt` | Allows everything, declares content signals, names the sitemap index |
| `/.well-known/security.txt` | The RFC 9116 security contact |
| `/.well-known/ai-catalog.json`, `/.well-known/api-catalog` | Pointers to the docs MCP server's card, for agent registries |
| `/.well-known/agent-skills/index.json` | A skill for the host and every public site's own, re-addressed from the root |
| `/webmcp.js` | The landing page's WebMCP tools: list the sites, search them, read a page, open a site |

A site's title and summary there are read from its own `llms.txt`, which the build writes
from `site_name` and `site_description`. Those two keys in your `mkdocs.yml` are what the
root says about your site, and the `[[services]]` block is the only thing to register.

The router also sets the security headers every response on the host carries, serves `.txt`
and `.md` as UTF-8, and answers `Accept: text/markdown` on a page with that page's
`index.md`, so a site Worker needs none of it.

If you keep a documentation hub elsewhere, such as a Docs page on your main site, set
`LANDING_REDIRECT` under `[vars]` in the router's `wrangler.toml` to its `https` URL. `/` then
answers a `302` there instead of serving the landing page, keeping the discovery `Link`
header. A client whose first media range is `text/markdown` still gets the index, and every
other path above is unchanged. Blank, or anything but an `https` URL, and `/` serves the
landing page. Set it only once that page is live: the redirect does not check. The landing
page's WebMCP tools go with it: a browser, a scanner's included, then reads the tools of the
page it was sent to, so that page needs its own for the host to pass `webMcp`.

#### Keeping a private site private

`cloudflare-docs-require-access: true` makes the deploy ask Cloudflare which Access
applications exist and refuse to publish unless one actually covers `<host>/<repo>`:

```yaml
          cloudflare-docs-require-access: 'true'
```

"The site is behind Access" is otherwise a belief that nothing checks, falsified silently the
day an application is renamed or its domain edited. This is the one moment something can ask.

The API token needs the **`Access: Apps` read** permission for this. Cloudflare's "Edit
Cloudflare Workers" template does not include it, and a `403` is reported as *could not tell*
rather than as "nothing covers it" — the two look alike in the response and collapsing them
would publish a private site while reporting that it checked.

The repository's name also belongs in `PRIVATE_SITES` in the router's `wrangler.toml`
before its `[[services]]` block lands. Access gates people, not the router's own reads over
the binding, so without it the public landing page, `/llms.txt` and the sitemap index would
list the site with the title and summary from its `llms.txt`.

#### The docs corpus

The build already holds every page it just rendered, so it emits a machine-readable copy of
the site at no extra cost: `llms.txt` (a link index) and `llms-full.txt` (every page's text)
are written into the site before it is published, and a search index of every page is
generated beside it. On by default (`cloudflare-docs-index`), with no credentials and no
network.

The corpus is what the build rendered, not everything under `docs/`. A file the build left
out (`exclude_docs`, `draft_docs`) is not indexed, because its URL would 404; the step's log
names each one.

`llms.txt` links each page's markdown twin when the metadata step above wrote one, as
llmstxt.org asks, and the page itself otherwise. The search index always cites the page.

Name a bucket and a deploy also publishes that index to R2 as `index/<repo>.json`, which is
the corpus the documentation MCP servers read:

```yaml
          cloudflare-docs-index-bucket: magmamoose-docs-index
```

Only a deploy writes it, and only after the site itself deployed: there is one key per
repository, so a pull request would otherwise overwrite the shared corpus with an unmerged
branch, and an index published ahead of a failed deploy would cite pages nobody serves. The
token needs **R2 object write** on top of the Workers permissions. The upload is not
failure-isolated: a run that deployed the site and quietly failed to publish the index would
be green while every agent read the previous commit's documentation.

#### The capability registry

The corpus answers questions about documentation. It cannot answer the one an agent asks
*before* it writes a workflow — which house tool already does this, how do I consume it, and
if none does, where do I file? Prose has to be interpreted, it does not carry the `uses:`
ref, and it cannot say **no**: four pages read and nothing found is indistinguishable from a
tool that has not published, and those two lead to opposite actions.

So a tool declares what it does, in a file at its own root, and this deploy ships it to
`capability/<repo>.json` beside the index:

```json
{
  "schema": 1,
  "repo": "tremvok",
  "private": false,
  "file_issues_at": "MagmaMoose/tremvok",
  "action": { "uses": "MagmaMoose/tremvok@v2", "kind": "composite-action" },
  "capabilities": [
    {
      "id": "cloudflare-docs",
      "summary": "Build an MkDocs site strictly and publish it to Cloudflare Workers.",
      "ecosystems": ["python", "mkdocs"],
      "inputs": ["cloudflare-docs-host", "cloudflare-docs-index-bucket"],
      "excludes": ["a docs site that is not MkDocs", "publishing to GitHub Pages"],
      "doc": "docs/setup.md"
    }
  ]
}
```

`cloudflare-docs-capability-file` names it, defaulting to `capability.json`; empty turns it
off. **Absent is the normal case** — most repositories are not house tools — and a run that
finds no file uploads nothing and says so in its summary.

`excludes` is the field that earns its keep, and the one worth writing first. A capability
that only says what it covers gets returned for cases it cannot serve, and the symptom is a
check that passes having measured nothing. A capability that declares none is warned about.

**A declaration that does not validate fails the run**, on a pull request as much as on a
deploy. The schema is
[`capability.schema.json`](https://mcp.magmamoose.com/schema/capability.schema.json), and the
reason for refusing rather than uploading is what the MCP does with a broken document: it
reads it as private and reports it as unreadable, counted and never named. A tool that
vanished because its JSON broke looks exactly like a tool that declared nothing, from the
only side that could notice. Every problem is reported in one run, not one per attempt.

Validation runs on a pull request; the upload does not. There is one key per repository, so a
preview that wrote would overwrite the shared registry with an unmerged branch — but a
declaration only checked on `main` is checked after the merge that broke it.

Two fields are the publisher's rather than the file's. `commit` and `generated` are stamped
from the run, because a file in a repository cannot know which commit it shipped from. And
`private` is republished from the repository's own visibility on the same fail-closed rule as
the index: a declaration is public only when it asks to be **and** GitHub says the repository
is public. Two visibility rules over one bucket is one rule that eventually disagrees with the
other, and the direction it disagrees in is a leak.

### `cloudflare-workers`

```yaml
permissions: { contents: read, pull-requests: write }

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: npm run build                       # your build, not Tremvok's
      - uses: MagmaMoose/tremvok@v2
        with:
          target: cloudflare-workers
          artifact-path: dist                    # the Worker's asset directory
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Two secrets, and no GitHub permission for the deploy itself: Cloudflare doesn't need one, so
`pull-requests: write` is there only for the sticky preview comment. Mint the API token from
Cloudflare's **"Edit Cloudflare Workers"** template rather than a hand-picked permission list,
or the first deploy of a custom domain fails on a permission nobody thought to grant. Pass the
account id as a secret too.

**Your `wrangler.toml` (or `wrangler.jsonc`) stays authoritative.** It owns the asset
directory, the routes, custom domains and 404 handling, so what ships matches what's reviewed
in the repository. The inputs are overrides for the few things a workflow legitimately varies
between runs: `artifact-path` is passed as `--assets`, `cloudflare-worker-name` as `--name`,
`cloudflare-env` as `--env`, and `cloudflare-config` points at the file when it isn't where
Wrangler would look.

The mode decides which Wrangler command runs:

| Event | Mode | Wrangler |
|---|---|---|
| push to the default branch, or `workflow_dispatch` | `deploy` | `wrangler deploy`, live on the routes in your config |
| pull request | `preview` | `wrangler versions upload --preview-alias pr-<number>` |

**A preview takes no production traffic.** `versions upload` uploads the version and gives it
its own URL; it never moves the live routes, which a plain `deploy` would. The alias is the
pull request number, so the link in the comment is stable across pushes. A branch name isn't:
it changes, and it isn't always URL-safe.

#### Validating a pull request without publishing it

A preview still runs the pull request's code with the Worker's real bindings. For a Worker
whose bindings reach data an unreviewed branch shouldn't run against (a private R2 bucket, a
production database), don't preview: dry-run the pull request instead.

```yaml
          dry-run: ${{ github.event_name == 'pull_request' }}
```

On this target a dry run is Wrangler's own `wrangler deploy --dry-run`: it bundles the Worker
and validates its configuration, uploads nothing, and calls no API, so it needs **no
credentials**. A fork's pull request, or a repository whose deploy token doesn't exist yet,
can still prove the Worker builds. A dry run that doesn't bundle fails the job.

#### A binding is only real if Wrangler prints it

`cloudflare-verify-config` (on by default) runs that same dry run before every publish and
refuses to publish when Wrangler reports configuration it won't apply:

- **an unexpected field.** A misspelled `[[r2_bucket]]` is only a *warning*: Wrangler exits 0
  and deploys a Worker with no bucket, and nothing fails until a request needs it;
- **a binding an `--env` deploy doesn't inherit**, which Wrangler also only warns about.

The offending lines are printed. It costs one extra bundle per run; set
`cloudflare-verify-config: false` to publish anyway.

Leave `cloudflare-main` empty for an assets-only Worker, which is the shape that serves files
straight from the edge with no cold start, no code in the request path, and asset requests
that aren't billed as invocations. Set it to your entry point for a Worker that runs code, and
add `cloudflare-build-command` if that code needs bundling first.

Wrangler is pinned (`cloudflare-wrangler-version`, 4.114.0 by default), because the tool that
publishes to production isn't a floating dependency. The action installs Node 24 for it:
Wrangler 4 declares `engines.node >= 22`, and on 20 it installs cleanly and then refuses to
run.

### `azure-functions-zip`

```yaml
permissions: { contents: read, id-token: write, pull-requests: write }

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-dotnet@v6
        with: { dotnet-version: '9.0.x' }
      - run: dotnet publish -c Release -f net9.0 -o publish
      - run: cd publish && zip -r -q ../package.zip .   # the CONTENTS, dotfiles included
      - uses: MagmaMoose/tremvok@v2
        with:
          target: azure-functions-zip
          artifact-path: package.zip
          azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
          azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
          azure-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
          functions-app-name: ${{ vars.FUNCTIONS_APP_NAME }}
          functions-resource-group: ${{ vars.FUNCTIONS_RESOURCE_GROUP }}
```

**No publish profile.** The Azure quickstarts hand you one, and it is a long-lived file
carrying the deployment rights of the whole site with nothing tying it to a repository.
`azure-client-id` is the alternative and the same argument as `aws-role-to-assume`: an Entra
ID app registration with a **federated credential** naming this repository and ref, a session
minted per run from the run's own OIDC token, and nothing at rest. That is what
`id-token: write` is for. Create the credential against
`repo:<owner>/<repo>:ref:refs/heads/main` (or an environment), and give the service principal
`Contributor` on the Function App's resource group — or `Website Contributor`, which is
narrower and enough.

A caller who would rather run `azure/login` in an earlier step can: leave `azure-client-id`
empty and the action uses the session already on the runner.

**Zip the contents of the publish directory, not the directory.** `cd publish && zip -r -q
../package.zip .` — because `zip -r package.zip publish` nests everything one level down and
`zip -r ../package.zip *` silently skips dotfiles. The worker reads `functions.metadata` and
loads its extensions from `.azurefunctions/`, both of which must be at the archive root. Get
this wrong and the package deploys perfectly cleanly and then serves nothing: no error, no log
line, a 404 on every route. Tremvok refuses such a package rather than letting you discover it
in production.

**Pin the runtime to `net9.0`.** `DOTNET-ISOLATED|10.0` is offered by the platform and
accepted by `az functionapp create`, and a Linux Consumption app on it never starts — the site
and its SCM endpoint both return 503, with no log output at all. 9.0 started first try with an
identical package.

**The exit code is not evidence, and neither is platform state.** `az functionapp deployment
source config-zip` has been observed printing `ERROR: Operation returned an invalid status
'Bad Request'` and exiting non-zero over a deploy that *succeeded*. So a non-zero exit is not
taken at face value: Tremvok asks the platform whether `WEBSITE_RUN_FROM_PACKAGE` actually
moved, and fails only if it did not. Nor does it trust the resource: an
`azurerm_linux_function_app` reports `state: Running` and `availabilityState: Normal` while
returning 503. After publishing, the app has to **answer**, and the run fails if it never
does. Any HTTP status counts, including the 404 a Function App returns at its root when its
only trigger is at `/api/<name>`; a connection failure and a 503 do not. A freshly created
Consumption app 503s from both the site and its SCM endpoint until content is first published,
so a first deploy retries through that rather than failing on it —
`functions-ready-attempts` × `functions-ready-delay` is the ceiling, five minutes by default.

`verify-url` sits on top of that and is where you assert what a particular route *does*: for a
webhook receiver, an unsigned request getting `401` is the check worth having — and it needs
`verify-method: POST`. The trigger binds POST and nothing else, so a GET reaches no function
and Azure answers `404`, which is also what a package containing no functions returns. Asserting
`POST` → `401` is what distinguishes a working deploy from a broken one; a GET against such a
route cannot.

**A pull request publishes nothing,** unless `functions-slot` is set. A slot is Azure's only
destination that does not take production traffic, and a Linux Consumption plan has no slots,
so on Consumption a preview validates the package and stops, saying why. On Premium or
Dedicated, set `functions-slot` and previews go to the slot.

### `azure-apim-policy`

Which Azure target fits a job is its own page:
[a Function or API Management?](azure-functions-or-api-management.md)

```yaml
permissions: { contents: read, id-token: write, pull-requests: write }

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: MagmaMoose/tremvok@v2
        with:
          target: azure-apim-policy
          artifact-path: apim/webhook        # api.xml and <operation-id>.xml
          apim-service-name: ${{ vars.APIM_SERVICE_NAME }}
          apim-resource-group: ${{ vars.APIM_RESOURCE_GROUP }}
          apim-api-id: webhook
          azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
          azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
          azure-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
          verify-url: https://example.azure-api.net/webhook/receive
          verify-method: POST
          verify-status: '401'
```

**The API is infrastructure; the policy is behaviour.** Create the instance, the API and its
operations with your infrastructure code. This target publishes the documents in
`artifact-path`: `api.xml` to the API scope and `<operation-id>.xml` to each operation. A
document named after an operation the API does not have is refused before anything is
published, rather than creating an operation nobody declared. Keep a policy published here out
of your infrastructure code, or the two will overwrite each other.

**The same sign-in as `azure-functions-zip`**, and the same federated credential. The service
principal needs `API Management Service Contributor` on the instance, or a custom role with
read on the service, its APIs and operations, and write on
`Microsoft.ApiManagement/service/apis/policies` and
`Microsoft.ApiManagement/service/apis/operations/policies`.

**All or nothing.** API Management compiles a policy, the XML and every C# expression in it,
only when it is published; there is no dry run. So Tremvok reads each scope's current policy
first, and if any document is refused it puts back the scopes it had already replaced (or clears
those that had none) and fails, naming the document and quoting API Management's reason.

**`rawxml` by default.** Write expressions the way the portal shows them, quotes and angle
brackets unescaped. Set `apim-policy-format: xml` for documents written as strict XML.

**Verify the behaviour, not the publish.** An accepted policy is live on the gateway within
seconds, so the publish proves little. Assert what the route does: for a webhook receiver, an
unsigned `POST` answering `401`. It needs `verify-method: POST`, because an operation that binds
POST answers a GET with `404` whatever its policy says.

**A pull request publishes nothing.** A policy's only destination that takes no production
traffic is an API revision, which this target does not create. A preview checks the documents
and stops, saying so.

### `s3-cloudfront` and `lambda-zip`

See [`examples/`](https://github.com/MagmaMoose/tremvok/tree/main/examples). Both need
`id-token: write` for the role, and `pull-requests: write` for the sticky preview comment.

### `terragrunt`

```yaml
on:
  pull_request:
  pull_request_review: { types: [submitted, dismissed] }
  push: { branches: [main], paths: ['terraform/**'] }
  schedule: [{ cron: '0 5 * * 1-5' }]   # the weekday drift run

permissions:
  contents: read
  id-token: write
  pull-requests: write
  checks: write          # the check run that makes apply-before-merge enforceable
```

An independent pull-request approval is the apply authorisation. Approving applies the
stacks, and the check run turns green once they are applied. `terragrunt-apply-operators`
names who may force one by hand; empty means nobody, so that path fails closed.

**Approving is what applies, and the run has to be the approval.** A `pull_request` run that
finds an approval already standing plans and reports rather than applying it: the approval was
given for the commit it was given for, and a commit pushed after it has not been reviewed. The
check run then reads `Approved, but not applied for this commit`. Dismiss the approval and
re-approve to apply the commit in front of you. This is what `pull_request_review` is doing in
the triggers above, and a workflow without it never applies at all. A review that is a comment
or a change request is not an approval either, so it plans.

**No AWS credential is required.** Terragrunt takes its credentials from the backend and
provider blocks in your own configuration, so an estate on Azure, GCP or a private cloud runs
without `aws-role-to-assume` and without `id-token: write`; drop both from the block above if
nothing in the run reaches AWS. [Per-stack state credentials](#per-stack-state-credentials)
below is how a state-backend key reaches one stack and not the others.

The gate is the action's own (`scripts/approval-gate.sh`), so it needs no GitHub
`environment:`. Add an `environment:` to your job only if you want what an environment adds
beyond the gate: a wait timer, or secrets scoped to it.

#### Letting a merge apply what it merged

Off by default. A push to the default branch plans and applies nothing unless you ask for
more:

```yaml
with:
  target: terragrunt
  terragrunt-apply-on-merge: 'true'
```

A push event carries no pull request, and the approval that authorises an apply belongs to the
pull request the commit was merged from. With this on, the run resolves that pull request from
the commit (`GET /repos/{repo}/commits/{sha}/pulls`, so squash, merge-commit and rebase merges
all resolve) and reads its reviews. Three outcomes, kept distinct on purpose:

| On the default branch, with apply-on-merge on | What happens |
| --- | --- |
| Merged from a pull request that had an independent approval | the affected stacks are applied, and the plan comment on that pull request is rewritten to the result |
| Merged without one, or pushed directly | plans and applies nothing, commenting on the merged pull request when there is one to comment on. The run exits `0` and the check run is `neutral` / `Planned; not applied` |
| The API could not be read, and there were pending changes | nothing is applied and the run **fails**, with a `failure` check run published first. An API outage must never read as "nobody approved" |

Where several merged pull requests are associated with one commit, the one whose base branch
is the branch that was pushed wins; among the rest, the oldest merge does. Neither unreadable
answer — the review list or the commit-to-pull-request lookup — refuses unless there was
something to apply, so a merge where every stack plans clean is not turned red by an API blip.
Both still warn, so a token missing `pull-requests: read` does not stay invisible until the
first merge that changes something.

An unapproved merge is reported rather than failed: it is a branch-protection matter, not a
broken build, and turning the default branch red does not fix it while leaving the stacks
unapplied and invisible would. The scheduled drift run keeps reporting them, and
`terragrunt-apply: force` applies them by hand.

`terragrunt-apply-on-merge` is deliberately not a value of `terragrunt-apply`. That input
answers "who may authorise an apply?"; this one answers "should a merge commit apply at all?".
With it on, the path needs `pull-requests: read` on the token, which the `pull-requests: write`
above already covers.

#### Which stacks a change plans

A stack is a directory holding `terragrunt.hcl`. On a pull request or a push, the changed
files decide which of them run:

| The change | The stacks it plans |
| --- | --- |
| A file inside a stack | that stack, however deep the file sits inside it |
| A file above the stacks, such as a shared `root.hcl` | every stack beneath that file's own directory, because every one of them includes it through `find_in_parent_folders` |
| A file directly in `terragrunt-root` | every stack, for the same reason |
| A file under `modules/` (or anything in `terragrunt-exclude`) | none |
| A file outside `terragrunt-root` | none |

A module maps to nothing on purpose: it has no state of its own, and guessing which stacks use
it from its path is how a small module tidy-up ends up planning the whole estate. The
scheduled drift run covers it. Everything above is per changed path and the results are
merged, so one pull request that edits a shared root and one stack plans that whole subtree
once.

#### Failing fast on an unreachable endpoint

Terragrunt buffers plan output to a file, so a state backend or provider API the runner cannot
reach is not an error: it is a silent wait until `terragrunt-timeout` with an empty log.
`terragrunt-preflight-urls` probes each URL once, with an 8-second timeout, before the first
plan:

```yaml
with:
  target: terragrunt
  # A repository variable, so an unset one probes nothing and the block is safe to copy.
  terragrunt-preflight-urls: ${{ vars.TERRAGRUNT_PREFLIGHT_URLS }}
```

Any HTTP answer passes, `401` and `403` included: an unauthenticated probe of a credentialed
endpoint is supposed to be refused, and being refused proves something is there. Only a curl
code of `000` fails, which is DNS, connection refused, a connect timeout or a TLS failure. A
`5xx` warns and passes, so a transient `503` cannot make this a flake. When something is
unreachable the step prints the runner's egress IP, which is the fact you need next if the
endpoint is IP-allowlisted.

It proves reachability, not authorisation. A passing `403` does not mean your credential
works. Blank lines and `#` comments are ignored, and these URLs are printed into the run log,
so put nothing secret in them. A URL carrying userinfo (`https://user:password@host/`) is
refused outright, and the refusal names the line by its index and shows the URL with the
userinfo replaced, rather than echoing the line. Empty (the default) probes nothing.

#### Planning a named pull request by hand

`terragrunt-pull-request` points a manual run at one pull request: its reviews are what the
approval gate reads, its thread is where the plan comment goes, and its head commit is what
the check run is published against.

```yaml
on:
  workflow_dispatch:
    inputs:
      pull_request:
        description: 'Pull request number to plan. Empty plans the default branch.'
        type: string
        default: ''

jobs:
  terragrunt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned sha>  # v7.0.1
        with:
          fetch-depth: 0
          # GitHub's merge of the pull request into its base: what lands on the default
          # branch if it merges. Empty falls back to the ref the run started from.
          ref: ${{ inputs.pull_request && format('refs/pull/{0}/merge', inputs.pull_request) || '' }}

      - uses: MagmaMoose/tremvok@v2
        with:
          target: terragrunt
          # Not optional here. Without it the action checks the workflow ref out again and
          # the merge tree is gone.
          checkout: false
          terragrunt-pull-request: ${{ inputs.pull_request }}
```

Checking out the right tree is yours, not Tremvok's: the action never fetches a merge ref, it
plans whatever is on disk. When the named pull request's head commit is not in that tree the
run warns and carries on, because `checkout: false` with a partial tree is a legitimate
choice. Two things fall out of this shape. You dispatch from the default branch and name the
pull request by number, so the "a manual run must start from main" rule still passes with no
exception. And `refs/pull/<n>/merge` does not exist while the pull request has conflicts, so
`actions/checkout` fails with git's own message before Tremvok runs at all.

`terragrunt-scope: auto` means the stacks that pull request touches whenever a pull request is
in scope, however it got there. `all` stays legal: plan the whole estate, gate on that pull
request's approval, comment on that pull request. A fork pull request is refused on this path,
exactly as the automatic one refuses fork code before it reaches a deploy credential.

### Credentials for the providers, which are not the state backend's

The most confusing failure this target has, and the one worth setting up before the first
run. A terragrunt run needs more than one credential, and they come from different places:

- **The state backend's**, which `terragrunt-stack-env` supplies per stack — an
  `ARM_ACCESS_KEY`, a role, a key file. See the section below.
- **Every provider's**, resolved by that provider's own chain, which nothing in the workflow
  mentions.

Supply the first and not the second and the run does not fail early or clearly. `init` reads
and writes state perfectly well, the plan starts, and then every stack dies inside a provider:

```text
Error: unable to build authorizer for Resource Manager API: could not configure AzureCli
Authorizer: tenant ID was not specified and the default tenant ID could not be determined:
obtaining tenant ID: obtaining account details: running Azure CLI: exit status 1:
ERROR: Please run 'az login' to setup account.

  with provider["registry.opentofu.org/hashicorp/azurerm"],
  on provider.tf line 25, in provider "azurerm":
```

Twenty times over, pointing at a `provider.tf` a `generate` block wrote and nobody has opened.
That reads as a broken runner. It is a credential nobody wired.

#### Azure

The same three inputs as `azure-functions-zip`, and the same federated credential:

```yaml
permissions: { contents: read, pull-requests: write, checks: write, id-token: write }

- uses: MagmaMoose/tremvok@v2
  with:
    target: terragrunt
    azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
    azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
    azure-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

The action signs in with this run's OIDC token before the first plan, and
`provider "azurerm"` with no explicit auth picks that session up from its default chain. Give
the app registration a federated credential for each subject the workflow runs under —
`repo:<owner>/<repo>:pull_request` for the plan on a pull request, and
`repo:<owner>/<repo>:ref:refs/heads/<default-branch>` for the apply, the post-merge run and
the schedule — with audience `api://AzureADTokenExchange`.

**On GitHub Enterprise Cloud with data residency the issuer is not
`https://token.actions.githubusercontent.com`.** It is `https://token.actions.<your-
subdomain>.ghe.com`. Read `/.well-known/openid-configuration` at that host and use the
`issuer` it returns; a federated credential built on the wrong one fails with a message that
blames the token rather than the issuer.

#### AWS

`aws-role-to-assume` applies to this target too, and has since the target existed — the step is
gated on the input, not on a target, so nothing extra is needed:

```yaml
- uses: MagmaMoose/tremvok@v2
  with:
    target: terragrunt
    aws-role-to-assume: arn:aws:iam::123456789012:role/tremvok-terragrunt
    aws-region: eu-west-1
```

The assumed-role session is exported into the environment, so both the S3 backend and the
`aws` provider find it in the default chain — one credential covers both, unlike Azure.

#### Google Cloud

```yaml
- uses: MagmaMoose/tremvok@v2
  with:
    target: terragrunt
    gcp-workload-identity-provider: projects/123456/locations/global/workloadIdentityPools/github/providers/tremvok
    gcp-service-account: tremvok@my-project.iam.gserviceaccount.com   # optional
    gcp-project-id: my-project                                        # optional
```

The full **provider** resource name, not the pool — a pool name is refused before any call is
made, because Google answers it with a 400 about an invalid audience that names nothing useful.

The action mints the run's OIDC token, writes it and a small `external_account` credential
configuration into `RUNNER_TEMP` at 0600, and exports `GOOGLE_APPLICATION_CREDENTIALS`. The
Terraform `google` provider reads that variable like every other Google client, and a GCS
backend uses the same credentials.

`gcp-service-account` is optional. Leave it empty when the IAM bindings name the pool's
`principalSet` directly; set it, and that principalSet needs `roles/iam.workloadIdentityUser`
on the service account.

Both halves are proved before the run continues, because they fail alike from inside Terraform
and have different fixes: an STS exchange that is refused means the pool provider's issuer or
attribute condition does not match this repository or ref, and an impersonation that is refused
means it does match and the `workloadIdentityUser` binding is missing. The error names which.

#### Anything else

Sign in during an earlier step, or hand the credential to the stacks that need it through
`terragrunt-stack-env`. The action does not care which; it checks that *something* is there.

#### The check that says so in one line

`terragrunt-credential-preflight` reads the `provider` blocks of every discovered stack, and
of every parent directory up to `terragrunt-root` so a shared `root.hcl` counts, and asks
whether this runner holds a credential for each cloud they name. On `auto`, the default, a
missing one fails the run before the first plan with the cloud, the stacks and the fix:

```text
## Terragrunt — a provider has no credential

### azure — 19 stack(s)

set azure-client-id, azure-tenant-id and azure-subscription-id (the action signs in with
this run's OIDC token), run azure/login in an earlier step, or hand the stack ARM_CLIENT_ID
and a secret through terragrunt-stack-env. ARM_ACCESS_KEY is the state backend's credential
and does not configure the provider.

- `terraform/azure/non-prod/westerneurope/aks` (provider "azurerm")
```

It knows azurerm/azuread/azapi, aws, google/google-beta and vcd, and passes over a provider it
does not recognise in silence rather than guessing. A provider block that configures its own
authentication — `client_id`, `credentials`, `api_token` and the rest — is not checked, because
that stack has answered the question itself.

It proves a credential is **present**, never that it is valid or that it reaches the
subscription, project or account the stack names — the same line
`terragrunt-preflight-urls` draws between reachable and authorised. `warn` annotates and plans
anyway; `off` checks nothing.

### Per-stack state credentials

If your production state lives in a different storage account from the rest, which is a
deliberate blast-radius boundary rather than an accident, one credential can't reach both.
`terragrunt-stack-env` applies environment per stack:

```yaml
with:
  target: terragrunt
  terragrunt-stack-env: |
    */prd/*|*/prod/*  ARM_ACCESS_KEY=${{ secrets.PRD_STATE_KEY }}
    *                 ARM_ACCESS_KEY=${{ secrets.STATE_KEY }}
```

One `<glob> KEY=VALUE` per line. The first matching line wins for a given key, so the
specific pattern goes above the catch-all, exactly as it would in a `case`. Blank lines and
`#` comments are ignored, and a line with a pattern but no assignment fails the run rather
than being skipped.

The values are secrets, so they're passed to each invocation with `env` rather than exported
into the shell: one stack's credential never reaches the next stack's run. The apply gets the
same environment the plan got, which matters more than it sounds. A plan that reads state
with one credential and an apply that writes it with another is the worst version of this
bug, because the plan looks fine.

### `ansible`

```yaml
permissions: { contents: read, pull-requests: write }
```

Runner-agnostic on purpose. A fleet reachable only from inside a private network needs a
self-hosted runner that sits in it. That's your `runs-on:`, and the action does not check,
because the same playbook against reachable hosts is a legitimate use.

#### Letting the playbook read its own Vault secrets

`vault-addr` and `vault-token` let the action resolve `ansible-*-vault` references. They live
in the step's environment, and by default the action removes them before `ansible-playbook`
starts: a token scoped to the fields Tremvok reads would otherwise be usable by every task,
role and collection in the play, and nobody chose that.

`ansible-vault-passthrough: true` chooses it. `VAULT_ADDR`, `VAULT_TOKEN` and
`VAULT_NAMESPACE` are then passed to the playbook, so it can read its own secrets from the
same Vault instead of having them copied into a second store that quietly stops being
rotated. The token is masked. Without both `vault-addr` and `vault-token` set, nothing is
passed and the run says so. Nothing to do with ansible-vault the file-encryption tool; that is
`ansible-vault-password`.

## An IAM role the workflow can assume

For the three targets that can use an AWS role. `s3-cloudfront` and `lambda-zip` need one, and
`terragrunt` needs one only when its own backend or providers reach AWS. Tremvok authenticates
with this run's GitHub OIDC token; nothing is stored in the repository.
The role's trust policy is what decides who may use it. Scope
it to the repository **and** the refs that may deploy:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:my-org/my-site:ref:refs/heads/main" }
  }
}
```

`StringLike` on `sub` with a `ref:` prefix, not `repo:owner/name:*`. The wildcard form lets a
pull request from a branch in the same repository assume a production deploy role.

Grant it only what the target needs. For `s3-cloudfront` that's `s3:PutObject`,
`s3:DeleteObject`, `s3:ListBucket` on the one bucket, and `cloudfront:CreateInvalidation` on
the one distribution.

## Secrets for the ansible target

The SSH key and the vault password arrive as repository or organisation secrets, passed as
inputs. Tremvok masks each on receipt, writes them to `0600` files under `$RUNNER_TEMP`, and
removes them with a trap that fires however the step exits, nothing reaches a command line,
where `ps` would show it.

```yaml
with:
  target: ansible
  ansible-playbook: ansible/site.yml
  ansible-inventory: ansible/inventory/production
  ansible-ssh-private-key: ${{ secrets.ANSIBLE_SSH_KEY }}
  ansible-vault-password: ${{ secrets.ANSIBLE_VAULT_PASSWORD }}
  ansible-ssh-known-hosts: ${{ secrets.ANSIBLE_KNOWN_HOSTS }}
```

`ansible-ssh-known-hosts` is optional and omitting it disables host-key checking, which the
run says out loud. Supply it for anything reachable from a network you do not control.

### Reading them from HashiCorp Vault instead

If a secret already lives in Vault, name it by reference rather than copying it into a GitHub
secret. A copy is a second thing to rotate, and the failure mode is silent: you rotate in
Vault, the copy keeps working, and nobody finds out until it doesn't.

```yaml
with:
  target: ansible
  ansible-playbook: ansible/site.yml
  ansible-inventory: ansible/inventory/production
  vault-addr: https://vault.example.com:8200
  vault-token: ${{ secrets.VAULT_TOKEN }}
  ansible-ssh-private-key-vault: secret/data/team/app#ssh_private_key
```

The reference is `<path>#<field>`. Each `-vault` input is the **alternative** to the literal
one, never a supplement: setting `ansible-ssh-private-key` and `ansible-ssh-private-key-vault`
together fails rather than quietly preferring one. `ansible-ssh-known-hosts-vault` and
`ansible-vault-password-vault` work the same way.

!!! note "Two different products called Vault"
    `vault-addr` and `vault-token` are HashiCorp Vault. `ansible-vault-password` is
    ansible-vault, the file-encryption tool, and has nothing to do with it. That's why the
    HashiCorp inputs aren't prefixed `ansible-vault-`: it would read as the wrong one.

KV v1 and v2 both work without you saying which: v2 nests the payload one level deeper, and
both shapes are tried. If you're on v2 the path needs its `/data/` segment
(`secret/data/team/app`, not `secret/team/app`), and a 404 says so.

The token needs read on the paths you reference and nothing else. What comes back is masked
and written to a `0600` file exactly like a literal secret, on the same single code path, and
a failed read fails the run rather than continuing with no key.

## (Optional) The Tremvok API

Only needed for deployment history, or for notifications that do not put a webhook URL in
every repository.

Deploying it is described in
[terraform/README.md](https://github.com/MagmaMoose/tremvok/blob/main/terraform/README.md);
the short version is that the module needs an artifact bucket, two SSM parameters written by
hand, and `allowed_owners` set to the GitHub owners you actually control. Then add
`api-url:` to the action and `permissions: id-token: write`. The repository stores nothing.

## Verify it, properly

After the first deploy of any new wiring:

```bash
curl -si https://your-site/ | head -1        # the site answers
```

and for the API, a **real signed POST**, not a `GET /healthz`. A health check passing proves
the function imported; it proves nothing at all about the write path, the table, or the IAM
policy. The LocalStack smoke suite exists to make that distinction cheap to test.
