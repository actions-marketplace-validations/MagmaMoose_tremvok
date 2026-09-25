/**
 * WebMCP on the landing page: the tools a browser agent can call on docs.magmamoose.com/.
 *
 *   list_docs_sites   every documentation site on the host, with its summary
 *   search_docs       pages matching a query, across every site's llms.txt
 *   read_page         any page on the host, as markdown
 *   open_site         navigate the tab to one site
 *
 * The landing page loads it as a same-origin script, `/webmcp.js`, which the page's CSP already
 * admits (`script-src 'self'`): no inline script and no hash to keep in step. The API is
 * https://webmachinelearning.github.io/webmcp/.
 *
 * THE BROWSER CODE IS A STRING, AND IT HAS TO BE. The obvious alternative, a function here served
 * as `fn.toString()`, passes every test in Node and breaks in production: Wrangler bundles with
 * esbuild's `keepNames`, which wraps each named function in a call to a `__name` helper that
 * exists in the bundle and not in the page, so the served script throws a ReferenceError before
 * it registers anything. A string is served byte for byte whatever the bundler does. The router's
 * tests run exactly these bytes in an empty context, which is what proves they are
 * self-contained, and parse them, which is what a syntax error would fail.
 *
 * Inside the string: no backtick and no dollar-brace, since either would end or interpolate the
 * template it lives in, so the code concatenates. `String.raw` keeps every backslash as written.
 *
 * THE SAME RULES AS EVERY SITE'S OWN SCRIPT (tremvok's scripts/docs_webmcp.js): feature-detected
 * and never defined, registered at once rather than on an event, and nothing fetched or opened
 * outside this host.
 */

/** Where the landing page loads it from. */
export const LANDING_SCRIPT_PATH = "/webmcp.js";

/** The script `/webmcp.js` serves. */
export const LANDING_SCRIPT = String.raw`(() => {
  "use strict";

  // One registration per document, however many times this runs.
  const FLAG = "__docsRouterWebMcp";
  if (window[FLAG]) return;
  // Feature-detected, never defined: the spec's document.modelContext, and the older
  // navigator.modelContext that polyfills and readiness scanners shim. One object that is both
  // is used once.
  const contexts = [...new Set([document.modelContext, navigator.modelContext])].filter(
    (context) => Boolean(context) && typeof context.registerTool === "function",
  );
  if (contexts.length === 0) return;
  const controller = new AbortController();
  window[FLAG] = { controller };

  const LIMIT = 10;
  const MAX_LIMIT = 25;
  const origin = location.origin;

  // The MCP tool-result shape. isError marks a refusal as the tool's answer, not a crash.
  const reply = (value) => ({
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
  });
  const refuse = (message) => ({ content: [{ type: "text", text: message }], isError: true });

  // A URL on this host, or null. Nothing a tool reads or opens is anywhere else.
  function resolve(value) {
    try {
      const url = new URL(String(value), location.href);
      url.hash = "";
      return url.origin === origin ? url : null;
    } catch {
      return null;
    }
  }

  // The sites, from this page's own JSON-LD ItemList: the router rendered it from the same data
  // as the cards, already escaped, so there is nothing to fetch and nothing to parse twice.
  function sites() {
    for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
      let data;
      try {
        data = JSON.parse(node.textContent);
      } catch {
        continue;
      }
      const graph = Array.isArray(data && data["@graph"]) ? data["@graph"] : [data];
      const list = graph.find((item) => item && item["@type"] === "ItemList");
      if (!list || !Array.isArray(list.itemListElement)) continue;
      const found = [];
      for (const item of list.itemListElement) {
        // The path only: the page names its canonical host, and the tools talk to this one.
        let path;
        try {
          path = new URL(String(item && item.url), origin).pathname;
        } catch {
          continue;
        }
        const name = path.split("/").filter(Boolean)[0];
        if (!name) continue;
        const home = origin + "/" + name + "/";
        found.push({
          name,
          title: String(item.name ?? name),
          summary: String(item.description ?? ""),
          url: home,
          llms_txt: home + "llms.txt",
          llms_full_txt: home + "llms-full.txt",
        });
      }
      return found;
    }
    return [];
  }

  function pick(value) {
    const wanted = String(value ?? "").trim().toLowerCase().replace(/^\/+|\/+$/g, "");
    return sites().find((site) => site.name === wanted || site.title.toLowerCase() === wanted);
  }

  const words = (value) => (String(value).toLowerCase().match(/[\p{L}\p{N}_]+/gu) || []).filter((w) => w.length > 1);

  // The page a markdown copy belongs to, which is the address to cite.
  function pageOf(link) {
    const page = new URL(link.href);
    if (page.pathname.endsWith("/index.md")) page.pathname = page.pathname.slice(0, -"index.md".length);
    else if (page.pathname.endsWith(".md")) page.pathname = page.pathname.slice(0, -3) + ".html";
    return page.href;
  }

  const pagesBySite = new Map();

  // One site's pages, from its llms.txt: "- [Title](url): summary", one line per page.
  async function pagesOf(site) {
    if (pagesBySite.has(site.name)) return pagesBySite.get(site.name);
    const response = await fetch("/" + site.name + "/llms.txt", { headers: { accept: "text/plain" } });
    if (!response.ok) return [];
    const found = [];
    for (const line of (await response.text()).split("\n")) {
      const match = /^- \[((?:\\.|[^\]\\])+)\]\((\S+?)\)(?::\s*(.*))?$/.exec(line.trim());
      if (!match) continue;
      // By path, as for the sites: the file names its canonical host, and the pages it lists
      // are served here, under the site's own path, whatever that host is called.
      let link;
      try {
        link = new URL(new URL(match[2], origin).pathname, origin);
      } catch {
        continue;
      }
      if (!link.pathname.startsWith("/" + site.name + "/")) continue;
      const markdown = link.pathname.endsWith(".md") ? link.href : null;
      found.push({
        site: site.name,
        title: match[1].replace(/\\(.)/g, "$1"),
        url: markdown ? pageOf(link) : link.href,
        markdown,
        summary: match[3] ?? "",
      });
    }
    pagesBySite.set(site.name, found);
    return found;
  }

  async function searchDocs(input) {
    const query = String((input && input.query) || "").trim();
    const terms = [...new Set(words(query))];
    if (terms.length === 0) return refuse("search_docs needs a query with at least one word in it.");
    const limit = Math.min(Math.max(Number.parseInt(input.limit, 10) || LIMIT, 1), MAX_LIMIT);
    let scope = sites();
    if (input.site) {
      const site = pick(input.site);
      if (!site) return refuse("There is no documentation site called " + input.site + " here. list_docs_sites names them.");
      scope = [site];
    }
    const pages = (await Promise.all(scope.map((site) => pagesOf(site).catch(() => [])))).flat();
    const scored = [];
    for (const page of pages) {
      const title = page.title.toLowerCase();
      const summary = page.summary.toLowerCase();
      let score = 0;
      let matched = 0;
      for (const term of terms) {
        const inTitle = title.includes(term);
        const inSummary = summary.includes(term) || page.site.includes(term);
        if (inTitle || inSummary) matched += 1;
        score += (inTitle ? 10 : 0) + (inSummary ? 3 : 0);
      }
      // Every word found beats any score made of some of them.
      if (matched > 0) scored.push({ page, score: score + (matched === terms.length ? 1000 : 0) });
    }
    scored.sort((a, b) => b.score - a.score);
    return reply({ query, results: scored.slice(0, limit).map(({ page }) => page) });
  }

  async function readPage(input, options) {
    const target = input && input.url ? resolve(input.url) : null;
    if (!target) return refuse("read_page reads pages on " + origin + " only, and needs the page's URL.");
    const signal = options && options.signal;
    // The router answers a page asked for as markdown with its index.md copy where the site
    // publishes one, and with the HTML page where it does not.
    const response = await fetch(target, { headers: { accept: "text/markdown" }, signal });
    if (!response.ok) return refuse(target.href + " answered " + response.status + ".");
    const body = await response.text();
    if (!/html/i.test(response.headers.get("content-type") ?? "")) return reply(body);
    const parsed = new DOMParser().parseFromString(body, "text/html");
    const region = parsed.querySelector("article") || parsed.querySelector("main") || parsed.body;
    if (!region) return reply("");
    // The permalink every heading carries is a pilcrow, not part of the heading.
    for (const link of region.querySelectorAll(".headerlink")) link.remove();
    return reply(region.textContent.replace(/\n\s*\n\s*\n+/g, "\n\n").trim());
  }

  function openSite(input) {
    const site = pick(input && input.site);
    if (!site) return refuse("There is no documentation site called " + (input && input.site) + " here. list_docs_sites names them.");
    location.assign("/" + site.name + "/");
    return reply("Opening " + site.url);
  }

  const tools = [
    {
      name: "list_docs_sites",
      title: "List the documentation sites",
      description: "List every documentation site on this host: its name, title, one-line summary, URL, and its llms.txt and llms-full.txt.",
      inputSchema: { type: "object", properties: {} },
      annotations: { readOnlyHint: true },
      execute: async () => reply({ sites: sites() }),
    },
    {
      name: "search_docs",
      title: "Search the documentation",
      description: "Search the pages of every documentation site on this host, or of one, by title and summary, from each site's llms.txt. Returns each match's page URL, its markdown URL and its summary.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "The words to look for." },
          site: { type: "string", description: "Only this site, by the name list_docs_sites gives." },
          limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: "How many results to return, " + LIMIT + " by default." },
        },
        required: ["query"],
      },
      annotations: { readOnlyHint: true },
      execute: searchDocs,
    },
    {
      name: "read_page",
      title: "Read a page as markdown",
      description: "Return any documentation page on this host as markdown. Cite the page URL, not the markdown's.",
      inputSchema: {
        type: "object",
        properties: { url: { type: "string", description: "The page, absolute or relative to this host." } },
        required: ["url"],
      },
      annotations: { readOnlyHint: true },
      execute: readPage,
    },
    {
      name: "open_site",
      title: "Open a documentation site",
      description: "Navigate this tab to one documentation site on this host.",
      inputSchema: {
        type: "object",
        properties: { site: { type: "string", description: "The site's name, as list_docs_sites gives it." } },
        required: ["site"],
      },
      execute: openSite,
    },
  ];

  for (const context of contexts) {
    for (const tool of tools) {
      try {
        const pending = context.registerTool(tool, { signal: controller.signal });
        if (pending && typeof pending.catch === "function") pending.catch(() => {});
      } catch {
        // A name already taken, or a browser that refuses: that tool goes unregistered.
      }
    }
  }

  // Unregistered when the document is discarded; a page kept for back and forward keeps them.
  addEventListener("pagehide", (event) => {
    if (!event.persisted) controller.abort();
  });
})();
`;
