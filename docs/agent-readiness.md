# Agent readiness

<!-- sources: scripts/gen_docs_agents.py, scripts/docs_webmcp.js, workers/docs-router/ -->

A docs site built by either docs target is readable and usable by AI agents without any setup:
the build writes what an agent looks for into the site it publishes. A few things live outside
the site (DNS records, zone rules, an OAuth server), and those are the owner's to add. This page
says which is which. The yardstick is [isitagentready.com](https://isitagentready.com/), whose
check names are used below, and a scan says where a host stands:

```bash
curl -s -X POST https://isitagentready.com/api/scan \
  -H 'content-type: application/json' -d '{"url":"https://docs.example.com"}' | jq .checks
```

## What every build writes

Three steps after `mkdocs build`, on `github-pages` and `cloudflare-docs` alike. None needs
credentials or network, each is on by default, and each leaves alone whatever the site already
publishes of its own.

| Check | What the build writes | Step (input) |
|---|---|---|
| `markdownNegotiation` (half of it) | every page's markdown at `<page>/index.md`, linked from the page | page metadata (`pages-seo`) |
| llms.txt, llms-full.txt | `/llms.txt` and `/llms-full.txt` (`cloudflare-docs` only) | the corpus (`cloudflare-docs-index`) |
| `agentSkills` | `/.well-known/agent-skills/index.json` and one `SKILL.md` | agent readiness (`pages-agent-ready`) |
| `webMcp` | WebMCP tools on every page, from `assets/javascripts/webmcp.js` | agent readiness (`pages-agent-ready`) |
| `authMd` | `/auth.md`, for a site at the root of its host | agent readiness (`pages-agent-ready`) |

### The skill

`/.well-known/agent-skills/index.json` follows the [Agent Skills Discovery
RFC](https://github.com/cloudflare/agent-skills-discovery-rfc) (v0.2.0) and lists one skill,
`/.well-known/agent-skills/<name>/SKILL.md`, which tells an agent:

- what the site covers: `site_description` and the top of the nav, a line per section with the
  pages in it;
- how to read it: `llms.txt`, `llms-full.txt`, the markdown copy of each page, asking a page URL
  for `Accept: text/markdown`, the MCP server when one is configured, and the WebMCP tools;
- how to cite it: the page URL, never the markdown copy's.

Each of those is mentioned only when the build actually wrote it. `github-pages` writes no
`llms.txt`, and `pages-seo: false` writes no markdown copies, so the skill does not send an agent
to either.

The index carries the SHA-256 of the exact bytes written, which a client checks before it loads
the skill. The name is `site_name` lowercased and hyphenated (`Caleb Sargeant's Docs` becomes
`caleb-sargeants-docs`), and the skill's URL in the index is path-absolute at the address the
site is served from (`/<repo>/.well-known/...` behind a router). MkDocs leaves dot-directories
out of the build, which is why the step writes these into the built site rather than reading
them from `docs/`. On `github-pages` the Pages artifact then includes dot-directories, since
`actions/upload-pages-artifact` drops them otherwise and the index would never be published.

### WebMCP

Every page loads one same-origin script, deferred, which registers four tools with the browser's
model context ([WebMCP](https://webmachinelearning.github.io/webmcp/)):

| Tool | What it does |
|---|---|
| `search_docs` | searches MkDocs' own search index (or `llms.txt` without one), best match first |
| `read_page` | returns a page of the site as markdown, the open page by default |
| `list_pages` | lists every page with its title, URL and markdown URL |
| `open_page` | navigates the tab to another page of the site |

The script uses `document.modelContext` and `navigator.modelContext`, whichever the browser has,
and never defines either. It registers on load rather than on an event, because a scanner reads
the registrations a few seconds after navigation. It fetches nothing until a tool runs, and
nothing outside the site: every URL a tool is handed is checked against the site's root, which
the script finds from its own address, so it works at `/` and at `/<repo>/` alike. A CSP of
`script-src 'self'` and `connect-src 'self'` admits all of it. In a browser without WebMCP it
does nothing at all.

### auth.md

Written only when the site is served at the root of its host (`site_url` with a path of `/`),
because `/auth.md` speaks for the host, and never for a site behind Cloudflare Access
(`cloudflare-docs-require-access`), which nobody reads without signing in. A GitHub Pages site
with access control turns it off with `auth_md: false`. It says what is true of a public static
site: reading needs no account, there is nothing to register for, and no credential is sent.
When an MCP server is configured it names it and points at the server's own OAuth
protected-resource metadata (RFC 9728) as the authority on its access, rather than restating it.

That is what keeps it from contradicting a real one. A host that routes `/auth.md` to an MCP
Worker (see [OAuth](#oauth-for-an-mcp-server-on-the-docs-host) below) never serves this file at
that path, because the route answers first; the copy only surfaces if the route goes, and it is
true either way.

### Configuration

Everything is optional, under `extra.agents` in `mkdocs.yml`. `extra` is a dict, so a shared
base can set it once through `INHERIT`:

```yaml
extra:
  agents:
    mcp: https://mcp.example.com/   # named in the skill and in auth.md
    skill:                          # or `false`: no skill
      name: example-docs            # default: site_name, lowercased and hyphenated
      description: ...              # default: from site_name and site_description
    webmcp: true                    # false: no WebMCP script
    auth_md: auto                   # auto: only at the root of a host; true; false
```

`pages-agent-ready: false` turns the whole step off, and the Pages artifact goes back to leaving
dot-directories out.

A site keeps what it already publishes: its own `/.well-known/agent-skills/`, whole; its own
`webmcp.js` at that path, with no page pointed at a second one; a page that already loads a
`webmcp.js`; and its own `auth.md`. The same rules make a second run change nothing.

## What the docs router adds

On a host shared by path, like `docs.magmamoose.com`, a client only ever looks at the host's
root, and each site's files sit under `/<repo>/`. The router in `workers/docs-router/` fills the
gap:

- **`/.well-known/agent-skills/index.json`** lists a skill for the host itself, then every public
  site's skills, read from each site's own index over the service binding, re-addressed from the
  root and cached like the `llms.txt` summaries. Sites in `PRIVATE_SITES` are never read.
- **WebMCP on the landing page**: `list_docs_sites`, `search_docs` across every site's
  `llms.txt`, `read_page` and `open_site`, from `/webmcp.js`, which the page's CSP admits as
  `'self'`. Only while `LANDING_REDIRECT` is blank: once `/` redirects, a browser (a scanner's
  included) reads the tools of the page it lands on, which then needs its own.
- **Markdown negotiation**: a page asked for with `Accept: text/markdown` is answered with its
  `index.md`, falling back to the HTML page where a site has none.
- CORS on every skills file, which the RFC asks for when browser-based clients read them.

A site behind the router gets no `auth.md` of its own: `/auth.md` on the host is the host's.

## What only the owner can do

### Markdown negotiation on a host of its own

The build writes the markdown; answering `Accept: text/markdown` with it happens before the
request reaches the site. The router does this for its host. A site on a host of its own needs
a URL rewrite Transform Rule on the zone (**Rules → Transform Rules → URL Rewrite**), which is
what `docs.calebsargeant.com` uses:

- **When incoming requests match**:

    ```text
    (http.host eq "docs.example.com"
     and ends_with(http.request.uri.path, "/")
     and starts_with(http.request.headers["accept"][0], "text/markdown"))
    ```

- **Path → Rewrite to → Dynamic**: `concat(http.request.uri.path, "index.md")`

The first media range has to be `text/markdown`, the rule the router follows too, so a browser
never gets markdown by accident. Unlike the router, a zone rule cannot fall back to the HTML
page, so every page needs its markdown copy, which the page metadata step writes for every page
the build emits. On `cloudflare-docs` add `Vary: Accept` and `Content-Type: text/markdown;
charset=utf-8` in the site's `_headers`. GitHub Pages can neither rewrite nor set a header, so a
site there needs a proxy in front of it (a Cloudflare zone does), or does without.

### DNS-AID records

The `dnsAid` check looks for [DNS for AI
Discovery](https://datatracker.ietf.org/doc/draft-mozleywilliams-dnsop-dnsaid/) records: SVCB
records under the host's `_agents` name, signed with DNSSEC. A docs host whose MCP server lives
elsewhere publishes, for example:

```text
_index._agents.docs.example.com. 3600 IN SVCB 1 docs.example.com. alpn="h2,h3" port=443
_mcp._agents.docs.example.com.   3600 IN SVCB 1 mcp.example.com.  alpn="mcp" port=443 mandatory=alpn,port
```

`_index` is the draft's well-known entry point, pointing at the host that describes what is
there; the second names the MCP endpoint, with the agent protocol in `alpn`. The draft's own
parameters (`cap`, `well-known` and the rest) have no registered code points yet, so use numeric
`keyNNNNN` names for them until they do. The zone needs DNSSEC switched on, or a validating
resolver never returns the records as authenticated. The scanner's
[dns-aid skill](https://isitagentready.com/.well-known/agent-skills/dns-aid/SKILL.md) has the
checks it runs.

### OAuth for an MCP server on the docs host

`oauthDiscovery`, `oauthProtectedResource` and a real `authMd` describe a server that issues
tokens, and a static site issues none. Serve them from the MCP server's own Worker, with Workers
routes on the zone for these paths of the docs host:

```text
docs.example.com/mcp*
docs.example.com/auth.md
docs.example.com/oauth/*
docs.example.com/agent/*
docs.example.com/.well-known/oauth-authorization-server*
docs.example.com/.well-known/oauth-protected-resource*
docs.example.com/.well-known/openid-configuration
```

A route is more specific than the site's own `docs.example.com/*` route, and takes precedence
over a Custom Domain such as the router's, so these paths reach the MCP Worker and everything
else still reaches the docs. The site's own `auth.md` stays in the build, shadowed at `/auth.md`
by the route, which is why it says nothing about the server that could go stale.

### Not covered

`a2aAgentCard` describes an agent that speaks the A2A protocol. A docs host runs none, so there
is no honest card to publish.
