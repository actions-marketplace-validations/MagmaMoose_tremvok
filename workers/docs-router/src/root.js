/**
 * The host root: the documents docs.magmamoose.com serves itself rather than from a site.
 *
 *   GET /                            the landing page, or a 302 to LANDING_REDIRECT when that is
 *                                    set; markdown to Accept: text/markdown either way
 *   GET /llms.txt                    an llmstxt.org index of every site
 *   GET /sitemap.xml                 a sitemap index of every site's sitemap.xml
 *   GET /robots.txt                  the crawl policy for the whole host
 *   GET /.well-known/security.txt    RFC 9116
 *   GET /.well-known/ai-catalog.json
 *   GET /.well-known/api-catalog     discovery, see discovery.js
 *   GET /.well-known/agent-skills/index.json
 *                                    the host's Agent Skills index: its own skill and every
 *                                    site's, see skills.js
 *   GET /.well-known/agent-skills/magma-moose-docs/SKILL.md
 *   GET /webmcp.js                   the landing page's WebMCP tools, see webmcp.js
 *
 * and a handful of redirects for paths clients ask for by convention (/favicon.ico).
 *
 * WHY THE ROUTER, AND NOT A SITE. Everything here is about the host, not one repository's
 * docs: robots.txt and a sitemap index only mean anything at the root, and a landing page
 * that belonged to one site would make that product look like the org's documentation. It
 * was a plain-text 404 until this existed, which crawlers read as "nothing here" and which
 * left robots.txt to Cloudflare's managed preamble, a file with no rules and no Sitemap line.
 *
 * NOTHING HERE IS A SECOND LIST OF SITES. Which sites exist comes from the service bindings,
 * what each is called from its own llms.txt (sites.js). The prose below is about the host,
 * never about a particular tool, so onboarding a repository changes nothing in this file.
 */

import {
  AI_CATALOG_PATH,
  AI_CATALOG_TYPE,
  API_CATALOG_PATH,
  API_CATALOG_TYPE,
  DISCOVERY_LINKS,
  LEGACY_SERVER_CARD_PATH,
  MCP_ENDPOINT,
  SERVER_CARD_URL,
  aiCatalog,
  apiCatalog,
  discoveryLinks,
} from "./discovery.js";
import {
  HOST_HEADERS,
  document,
  methodNotAllowed,
  pageCsp,
  prefersMarkdown,
  redirect,
  sha256Source,
} from "./headers.js";
import { ORIGIN, describeSites, listedRepos, siteUrl } from "./sites.js";
import { HOST_SKILL_PATH, SKILLS_INDEX_PATH, renderHostSkill, renderSkillsIndex } from "./skills.js";
import { LANDING_SCRIPT, LANDING_SCRIPT_PATH } from "./webmcp.js";

const WWW = "https://www.magmamoose.com";
const ORGANIZATION_ID = `${WWW}/#organization`;

// Checked 2026-09-23: 200, 1200x630.
const OG_IMAGE = `${WWW}/assets/og/og-magma-moose.png`;
const FAVICON_SVG = `${WWW}/assets/favicon.svg`;
const FAVICON_ICO = `${WWW}/assets/favicon.ico`;
const TOUCH_ICON = `${WWW}/assets/apple-touch-icon.png`;

const NAME = "Magma Moose documentation";

/** The meta description. Search engines cut it at about 155 characters, and a test holds it there. */
const DESCRIPTION =
  "Documentation for the open-source developer tools Magma Moose builds: setup guides, references and design notes, one site per tool.";

const LEDE =
  "Documentation for the open-source developer tools Magma Moose builds. Each tool has its own site: how to set it up, the full reference, and the reasoning behind its design.";

const SUMMARY =
  "Documentation for the open-source developer tools Magma Moose builds, one site per tool, each with its own llms.txt and llms-full.txt.";

// ── Escaping ──────────────────────────────────────────────────────────────────
//
// Titles and summaries come from each site's llms.txt. They are the fleet's own files, but
// this page is the one place all of them meet, so nothing from them reaches markup unescaped.

const HTML_ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => HTML_ESCAPES[c]);
}

/** JSON inside <script>: `</script>` in a summary must not end the element. */
function jsonForHtml(value) {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026");
}

/** Markdown link text: a bracket in a title must not end the link. */
function markdownText(value) {
  return String(value).replace(/([\\[\]])/g, "\\$1");
}

// ── The stylesheet ────────────────────────────────────────────────────────────
//
// Inline, because it is the page's only subresource and a round trip for 2 KB is the slowest
// thing the page could do. The CSP admits it by hash rather than with 'unsafe-inline', and
// the hash is computed from this constant at runtime, so editing the CSS cannot leave the
// policy describing the previous version of it.
//
// Brand tokens are Magma Moose's (www.magmamoose.com/brand/tokens.css): obsidian and paper
// grounds, molten for links. System fonts, so there is no font request and no layout shift.

const STYLE = [
  ":root{color-scheme:light dark;--bg:#EEE9E2;--panel:#FBF6EF;--text:#221A14;--muted:#5F5851;--line:rgba(34,26,20,.14);--link:#A12B10}",
  "@media (prefers-color-scheme:dark){:root{--bg:#0E0A07;--panel:#15100C;--text:#FBF6EF;--muted:#A2948A;--line:rgba(255,255,255,.1);--link:#FF8C5E}}",
  "*{box-sizing:border-box}",
  "html{-webkit-text-size-adjust:100%;text-size-adjust:100%}",
  'body{margin:0;background:var(--bg);color:var(--text);font:1rem/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}',
  "a{color:var(--link);text-underline-offset:.15em}",
  "a:focus-visible{outline:2px solid var(--link);outline-offset:3px;border-radius:2px}",
  ".wrap{max-width:60rem;margin:0 auto;padding:0 1rem}",
  "header{border-bottom:1px solid var(--line)}",
  "header .wrap{display:flex;align-items:center;min-height:3.5rem}",
  ".brand{display:inline-flex;align-items:center;gap:.6rem;color:var(--text);font-weight:600;text-decoration:none;padding:.5rem 0}",
  ".brand svg{width:1.75rem;height:1.75rem;flex:none}",
  "main{padding:2.5rem 0 3rem}",
  "h1{font-size:clamp(1.875rem,2.5vw + 1.25rem,2.75rem);line-height:1.15;letter-spacing:-.01em;margin:0 0 .75rem}",
  ".lede{font-size:1.125rem;color:var(--muted);max-width:42rem;margin:0 0 2rem}",
  ".sites{list-style:none;margin:0;padding:0;display:grid;gap:1rem}",
  "@media (min-width:44rem){.sites{grid-template-columns:repeat(2,minmax(0,1fr))}}",
  ".site{display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:.75rem;padding:1.25rem 1.25rem .75rem}",
  ".site h2{font-size:1.25rem;line-height:1.3;margin:0 0 .35rem}",
  ".site h2 a{text-decoration:none}",
  ".site h2 a:hover{text-decoration:underline}",
  ".site p{margin:0 0 .75rem;color:var(--muted)}",
  ".alt{margin-top:auto;display:flex;flex-wrap:wrap;gap:0 1.25rem;font:.875rem/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}",
  ".alt a{display:inline-block;padding:.4rem 0}",
  ".agents{margin-top:2.5rem;padding-top:1.5rem;border-top:1px solid var(--line);max-width:42rem}",
  ".agents h2{font-size:1.125rem;margin:0 0 .5rem}",
  ".agents p{margin:0 0 .75rem;color:var(--muted)}",
  "code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em;overflow-wrap:anywhere}",
  "footer{border-top:1px solid var(--line);color:var(--muted);font-size:.875rem}",
  "footer ul{list-style:none;margin:0;padding:1rem 0 2rem;display:flex;flex-wrap:wrap;gap:0 1.5rem}",
  "footer a{display:inline-block;padding:.4rem 0}",
].join("\n");

let pagePolicy = null;

/** The HTML pages' CSP, with the stylesheet's hash. Computed once per isolate. */
async function htmlCsp() {
  if (pagePolicy === null) pagePolicy = pageCsp(await sha256Source(STYLE));
  return pagePolicy;
}

/** The Magma Moose mark, inline: decoration, and no request. Same drawing as the favicon. */
const MARK = [
  '<svg viewBox="0 0 512 512" aria-hidden="true" focusable="false">',
  '<defs><linearGradient id="mm-g" x1="0" y1="0" x2="1" y2="1">',
  '<stop offset="0" stop-color="#FFB02E"/><stop offset="1" stop-color="#D8330F"/></linearGradient></defs>',
  '<rect width="512" height="512" rx="143" fill="url(#mm-g)"/>',
  '<g transform="translate(103 103) scale(2.558)" fill="#FBF6EF">',
  '<path d="M53 46 L50 30 L41 33 L40 21 L31 30 L27 19 L19 29 L13 24 L13 36 L22 41 L36 45 Z"/>',
  '<path d="M67 46 L70 30 L79 33 L80 21 L89 30 L93 19 L101 29 L107 24 L107 36 L98 41 L84 45 Z"/>',
  '<path d="M44 52 L31 47 L39 60 Z"/><path d="M76 52 L89 47 L81 60 Z"/>',
  '<path d="M60 42 C74 42 80 50 79 62 C78 76 71 90 60 102 C49 90 42 76 41 62 C40 50 46 42 60 42 Z"/>',
  "</g></svg>",
].join("");

// ── The pages ─────────────────────────────────────────────────────────────────

function page({ title, head, main }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
${head}
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#EEE9E2" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0E0A07" media="(prefers-color-scheme: dark)">
<link rel="icon" href="${FAVICON_SVG}" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="apple-touch-icon" href="${TOUCH_ICON}">
<style>${STYLE}</style>
</head>
<body>
<header><div class="wrap"><a class="brand" href="${WWW}/">${MARK}<span>Magma Moose</span></a></div></header>
<main><div class="wrap">
${main}
</div></main>
<footer><div class="wrap"><ul>
<li><a href="${WWW}/">magmamoose.com</a></li>
<li><a href="/llms.txt">llms.txt</a></li>
<li><a href="/sitemap.xml">Sitemap</a></li>
<li><a href="/.well-known/security.txt">Security contact</a></li>
</ul></div></footer>
</body>
</html>
`;
}

function structuredData(sites) {
  const website = `${ORIGIN}/#website`;
  const list = `${ORIGIN}/#sites`;
  return {
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "Organization", "@id": ORGANIZATION_ID, name: "Magma Moose", url: `${WWW}/` },
      {
        "@type": "WebSite",
        "@id": website,
        url: `${ORIGIN}/`,
        name: NAME,
        description: DESCRIPTION,
        inLanguage: "en",
        publisher: { "@id": ORGANIZATION_ID },
      },
      {
        "@type": "CollectionPage",
        "@id": `${ORIGIN}/#webpage`,
        url: `${ORIGIN}/`,
        name: NAME,
        description: DESCRIPTION,
        inLanguage: "en",
        isPartOf: { "@id": website },
        publisher: { "@id": ORGANIZATION_ID },
        mainEntity: { "@id": list },
      },
      {
        "@type": "ItemList",
        "@id": list,
        name: "Documentation sites",
        numberOfItems: sites.length,
        itemListElement: sites.map((site, index) => ({
          "@type": "ListItem",
          position: index + 1,
          name: site.title,
          url: siteUrl(site.repo),
          ...(site.summary ? { description: site.summary } : {}),
        })),
      },
    ],
  };
}

function siteCard(site) {
  const url = escapeHtml(`/${site.repo}/`);
  const title = escapeHtml(site.title);
  return [
    '<li class="site">',
    `<h2><a href="${url}">${title}</a></h2>`,
    site.summary ? `<p>${escapeHtml(site.summary)}</p>` : "",
    '<p class="alt">',
    `<a href="${url}llms.txt" aria-label="${title} llms.txt">llms.txt</a> `,
    `<a href="${url}llms-full.txt" aria-label="${title} llms-full.txt">llms-full.txt</a>`,
    "</p>",
    "</li>",
  ].join("");
}

export function renderLanding(sites) {
  const canonical = `${ORIGIN}/`;
  const description = escapeHtml(DESCRIPTION);
  const head = [
    `<meta name="description" content="${description}">`,
    `<link rel="canonical" href="${canonical}">`,
    '<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1">',
    `<link rel="ai-catalog" href="${AI_CATALOG_PATH}" type="${AI_CATALOG_TYPE}">`,
    `<link rel="api-catalog" href="${API_CATALOG_PATH}">`,
    '<meta property="og:type" content="website">',
    '<meta property="og:site_name" content="Magma Moose">',
    '<meta property="og:locale" content="en_GB">',
    `<meta property="og:title" content="${escapeHtml(NAME)}">`,
    `<meta property="og:description" content="${description}">`,
    `<meta property="og:url" content="${canonical}">`,
    `<meta property="og:image" content="${OG_IMAGE}">`,
    '<meta property="og:image:width" content="1200">',
    '<meta property="og:image:height" content="630">',
    '<meta property="og:image:alt" content="Magma Moose: platform engineering and developer tooling">',
    '<meta name="twitter:card" content="summary_large_image">',
    `<meta name="twitter:title" content="${escapeHtml(NAME)}">`,
    `<meta name="twitter:description" content="${description}">`,
    `<meta name="twitter:image" content="${OG_IMAGE}">`,
    '<meta name="twitter:image:alt" content="Magma Moose: platform engineering and developer tooling">',
    `<script type="application/ld+json">${jsonForHtml(structuredData(sites))}</script>`,
    // The page's one script, same-origin so `script-src 'self'` admits it with no hash. Deferred,
    // not async: it reads the JSON-LD above, and a deferred script runs once the page is parsed.
    `<script src="${LANDING_SCRIPT_PATH}" defer></script>`,
  ].join("\n");
  const list = sites.length
    ? `<ul class="sites">\n${sites.map(siteCard).join("\n")}\n</ul>`
    : "<p>No documentation sites are published yet.</p>";
  const main = [
    `<h1>${escapeHtml(NAME)}</h1>`,
    `<p class="lede">${escapeHtml(LEDE)}</p>`,
    list,
    '<section class="agents" aria-labelledby="agents">',
    '<h2 id="agents">For agents</h2>',
    '<p>Every site publishes an <a href="https://llmstxt.org/">llms.txt</a> and an llms-full.txt, and <a href="/llms.txt">/llms.txt</a> indexes all of them. <a href="/sitemap.xml">/sitemap.xml</a> lists every site\'s sitemap. A page asked for with <code>Accept: text/markdown</code> is answered with its markdown wherever its site publishes one.</p>',
    `<p>The same documentation is searchable over MCP at <code>${MCP_ENDPOINT}</code> (Streamable HTTP, no sign-in), and described for registries by the <a href="${AI_CATALOG_PATH}">AI Catalog</a> and the <a href="${API_CATALOG_PATH}">API catalog</a>.</p>`,
    `<p><a href="${SKILLS_INDEX_PATH}">An Agent Skills index</a> lists a skill for this host and one for each site, saying how to read and cite it. In a browser with <a href="https://webmachinelearning.github.io/webmcp/">WebMCP</a>, this page offers tools to list the sites, search them, read a page and open a site.</p>`,
    "</section>",
  ].join("\n");
  return page({ title: NAME, head, main });
}

function renderNotFound(repos) {
  const list = repos.length
    ? `<ul>\n${repos.map((repo) => `<li><a href="${escapeHtml(`/${repo}/`)}">${escapeHtml(repo)}</a></li>`).join("\n")}\n</ul>`
    : "";
  const main = [
    "<h1>Page not found</h1>",
    '<p class="lede">There is no documentation site at this address.</p>',
    repos.length ? "<p>The sites published here:</p>" : "",
    list,
    `<p><a href="/">All Magma Moose documentation</a></p>`,
  ].join("\n");
  return page({ title: `Not found · ${NAME}`, head: '<meta name="robots" content="noindex">', main });
}

/**
 * The index of every site, as llmstxt.org lays one out. The same text is the landing page's
 * markdown, since it is the same list for a reader that wants markdown.
 */
export function renderLlmsTxt(sites) {
  const lines = [
    `# ${NAME}`,
    "",
    `> ${SUMMARY}`,
    "",
    `The same documentation is searchable over MCP at ${MCP_ENDPOINT}: Streamable HTTP, stateless JSON-RPC over POST, no authentication. Every result it returns cites a page on ${ORIGIN.replace("https://", "")}. A page asked for with \`Accept: text/markdown\` is answered with its markdown wherever its site publishes one.`,
    "",
    "## Documentation sites",
    "",
    ...sites.map((site) => {
      const url = siteUrl(site.repo);
      const files = `[llms.txt](${url}llms.txt), [llms-full.txt](${url}llms-full.txt)`;
      const notes = site.summary ? `${site.summary} (${files})` : files;
      return `- [${markdownText(site.title)}](${url}): ${notes}`;
    }),
    "",
    "## Optional",
    "",
    `- [Sitemap index](${ORIGIN}/sitemap.xml): the sitemap of every site above`,
    `- [AI Catalog](${ORIGIN}${AI_CATALOG_PATH}): the MCP server's card, for agent registries`,
    `- [Agent Skills](${ORIGIN}${SKILLS_INDEX_PATH}): a skill for this host and one for each site, saying how to read and cite it`,
    `- [Magma Moose](${WWW}/): the studio that builds these tools`,
    "",
  ];
  return lines.join("\n");
}

function renderRobotsTxt() {
  return [
    "# docs.magmamoose.com: documentation for the open-source developer tools Magma Moose",
    "# builds. Everything here is public and meant to be read, by people, search engines and",
    "# agents alike.",
    "#",
    `# Agents: ${ORIGIN}/llms.txt indexes every site, and each site`,
    "# publishes its own /<site>/llms.txt and /<site>/llms-full.txt. The same documentation",
    `# is searchable over MCP at ${MCP_ENDPOINT} (Streamable HTTP, no authentication).`,
    "#",
    "# /cdn-cgi/ is Cloudflare's endpoint space, not documentation; Cloudflare recommends",
    "# keeping crawlers out of it.",
    "User-agent: *",
    "Content-Signal: search=yes, ai-input=yes, ai-train=yes",
    "Allow: /",
    "Disallow: /cdn-cgi/",
    "",
    `Sitemap: ${ORIGIN}/sitemap.xml`,
    "",
    "# The AI Catalog, for agent registries (Agentic Resource Discovery); other crawlers ignore it.",
    `Agentmap: ${ORIGIN}${AI_CATALOG_PATH}`,
    "",
  ].join("\n");
}

/** Every listed site's own sitemap. No fetch: the index needs only the route table. */
function renderSitemapIndex(repos) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">', // DevSkim: ignore DS137138 - the sitemap namespace is http:// by specification, an identifier that is never fetched
    ...repos.map(
      (repo) => `  <sitemap><loc>${escapeHtml(`${siteUrl(repo)}sitemap.xml`)}</loc></sitemap>`,
    ),
    "</sitemapindex>",
    "",
  ].join("\n");
}

/**
 * RFC 9116 wants Expires in the future, and a security.txt that has expired is itself a
 * finding in most scanners. Computed per request, as the first of the month six months on,
 * so it can never lapse and never needs a deploy to refresh.
 */
export function securityTxtExpiry(now) {
  const expires = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 6, 1));
  return expires.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function renderSecurityTxt(now) {
  return [
    "# Security contact for docs.magmamoose.com (RFC 9116).",
    "Contact: mailto:hello@magmamoose.com",
    `Expires: ${securityTxtExpiry(now)}`,
    "Preferred-Languages: en",
    `Canonical: ${ORIGIN}/.well-known/security.txt`,
    "",
  ].join("\n");
}

// ── Answering ─────────────────────────────────────────────────────────────────

const TEXT = "text/plain; charset=utf-8";
const MARKDOWN = "text/markdown; charset=utf-8";
const HTML = "text/html; charset=utf-8";

async function describedSites(request, env) {
  return describeSites(env, listedRepos(env), new URL(request.url).origin);
}

/**
 * Where `/` sends everything that did not ask for markdown: `LANDING_REDIRECT` in
 * wrangler.toml, meant for www.magmamoose.com/documentation/. That page lists the same public
 * sites in the studio's own design, under the Docs tab of the studio's nav, so a person who
 * types docs.magmamoose.com lands on the one documentation hub the org keeps, and every card
 * there leads back to a site on this host.
 *
 * A client whose first media range is text/markdown is not sent away: an agent asking this
 * host for markdown wants the docs' own index, which is the llms.txt below, not an HTML page
 * on another host. And the redirect keeps the discovery Link header, absolute, so a client
 * that reads headers without following the redirect still finds the catalogs and llms.txt.
 *
 * A 302, like the server card's, because the address is another repository's to move. A
 * value that is blank or not an https URL is ignored and the landing page is served, so
 * turning the redirect off is a config change and a typo cannot send anyone somewhere
 * broken.
 */
export function landingRedirect(env) {
  const value = typeof env.LANDING_REDIRECT === "string" ? env.LANDING_REDIRECT.trim() : "";
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

async function landing(request, env) {
  const markdown = prefersMarkdown(request.headers.get("accept"));
  const away = markdown ? null : landingRedirect(env);
  // Before describedSites: the redirect names no site, so it reads no site's llms.txt.
  if (away) {
    return redirect(away, 302, "public, max-age=300", { link: discoveryLinks(ORIGIN), vary: "Accept" });
  }
  const sites = await describedSites(request, env);
  const headers = { link: `<${ORIGIN}/>; rel="canonical", ${DISCOVERY_LINKS}`, vary: "Accept" };
  if (markdown) {
    return document(request, renderLlmsTxt(sites), { type: MARKDOWN, cache: "public, max-age=300", headers });
  }
  return document(request, renderLanding(sites), {
    type: HTML,
    cache: "public, max-age=300",
    csp: await htmlCsp(),
    headers,
  });
}

async function llmsTxt(request, env) {
  return document(request, renderLlmsTxt(await describedSites(request, env)), {
    type: TEXT,
    cache: "public, max-age=300",
  });
}

async function robotsTxt(request) {
  return document(request, renderRobotsTxt(), { type: TEXT, cache: "public, max-age=3600" });
}

async function sitemapIndex(request, env) {
  return document(request, renderSitemapIndex(listedRepos(env)), {
    type: "application/xml; charset=utf-8",
    cache: "public, max-age=3600",
  });
}

async function securityTxt(request) {
  return document(request, renderSecurityTxt(new Date()), { type: TEXT, cache: "public, max-age=86400" });
}

/**
 * Discovery documents: public metadata any origin may read and cache for an hour, with the
 * ETag readable cross-origin, which is what the Server Card extension asks of them.
 */
function discovery(value, type, extra = {}) {
  return (request) =>
    document(request, `${JSON.stringify(value, null, 2)}\n`, {
      type,
      cache: "public, max-age=3600",
      headers: {
        "access-control-allow-origin": "*",
        "access-control-expose-headers": "ETag",
        ...extra,
      },
    });
}

/**
 * The skills documents are public and read by clients that may run in a browser, which is when
 * the RFC asks for CORS. The ETag is exposed for the same revalidation the catalogs allow.
 */
const SKILLS_HEADERS = { "access-control-allow-origin": "*", "access-control-expose-headers": "ETag" };

async function skillsIndex(request, env) {
  const body = await renderSkillsIndex(env, listedRepos(env), new URL(request.url).origin, {
    landingTools: !landingRedirect(env),
  });
  return document(request, body, { type: "application/json", cache: "public, max-age=300", headers: SKILLS_HEADERS });
}

/**
 * The same max-age as the index. The index carries this file's digest, and a client holding a
 * fresher index than file (or the reverse) rejects the file until the older copy expires.
 */
async function hostSkill(request, env) {
  return document(request, renderHostSkill(listedRepos(env), { landingTools: !landingRedirect(env) }), {
    type: "text/markdown; charset=utf-8",
    cache: "public, max-age=300",
    headers: SKILLS_HEADERS,
  });
}

async function landingScript(request) {
  return document(request, LANDING_SCRIPT, { type: "text/javascript; charset=utf-8", cache: "public, max-age=300" });
}

const DOCUMENTS = {
  "/": landing,
  "/llms.txt": llmsTxt,
  "/robots.txt": robotsTxt,
  "/sitemap.xml": sitemapIndex,
  "/.well-known/security.txt": securityTxt,
  [SKILLS_INDEX_PATH]: skillsIndex,
  [HOST_SKILL_PATH]: hostSkill,
  [LANDING_SCRIPT_PATH]: landingScript,
  [AI_CATALOG_PATH]: discovery(aiCatalog(), AI_CATALOG_TYPE),
  // RFC 9727: the catalog names itself in a Link header, on HEAD as well as GET.
  [API_CATALOG_PATH]: discovery(apiCatalog(), API_CATALOG_TYPE, {
    link: `<${API_CATALOG_PATH}>; rel="api-catalog"`,
  }),
};

/**
 * Paths clients ask for by convention rather than by link. The icons are www.magmamoose.com's
 * so the brand has one copy; the card is MagmaMoose/mcp's (see discovery.js), and its
 * redirect is a 302 because the card's address is that repository's to move.
 */
const REDIRECTS = {
  "/favicon.ico": [FAVICON_ICO, 301],
  "/apple-touch-icon.png": [TOUCH_ICON, 301],
  "/apple-touch-icon-precomposed.png": [TOUCH_ICON, 301],
  "/security.txt": ["/.well-known/security.txt", 301],
  [LEGACY_SERVER_CARD_PATH]: [SERVER_CARD_URL, 302],
};

/**
 * The handler for a path the router answers itself, or null when the path belongs to a site
 * (or to nothing). Exact matches only: a site's own /<repo>/robots.txt is its business.
 */
export function rootHandler(pathname) {
  const answer = Object.hasOwn(DOCUMENTS, pathname) ? DOCUMENTS[pathname] : null;
  const moved = Object.hasOwn(REDIRECTS, pathname) ? REDIRECTS[pathname] : null;
  if (!answer && !moved) return null;
  return (request, env) => {
    if (request.method !== "GET" && request.method !== "HEAD") return methodNotAllowed();
    if (moved) {
      const [location, status] = moved;
      return redirect(location, status, status === 302 ? "public, max-age=300" : "public, max-age=86400");
    }
    return answer(request, env);
  };
}

/**
 * A path under no site. Still a 404, now a page a person can do something with: it links home
 * and lists what is here. It names only listed sites, without reading anything from them, so
 * a scanner walking /wp-admin/ and friends costs no site Worker invocations. The requested
 * path is never echoed back.
 */
export async function notFound(env) {
  return new Response(renderNotFound(listedRepos(env)), {
    status: 404,
    headers: {
      ...HOST_HEADERS,
      "content-security-policy": await htmlCsp(),
      "content-type": HTML,
      "cache-control": "public, max-age=60",
    },
  });
}
