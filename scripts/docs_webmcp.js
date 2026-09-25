/**
 * WebMCP tools for a documentation site: search it, read a page as markdown, list its pages,
 * open one.
 *
 * `scripts/gen_docs_agents.py` copies this file into every built site as
 * `assets/javascripts/webmcp.js` and loads it from each page's head with `defer`. It registers
 * four tools with the browser's model context, the in-page API a browser agent calls
 * (https://webmachinelearning.github.io/webmcp/). Where the browser has no such API it does
 * nothing at all: no global, no request, no listener.
 *
 * FEATURE-DETECTED, NEVER DEFINED. The spec puts the API on `document.modelContext`. The older
 * shape, and the one a polyfill or a readiness scanner shims, is `navigator.modelContext`.
 * Every one that exists is used, and one object that is both is used once. Defining either here
 * would claim a capability the browser does not have, and would shadow the real one the day it
 * ships.
 *
 * REGISTERED AT ONCE, NOT ON AN EVENT. isitagentready.com reads the registrations a few seconds
 * after navigation, and a registration that waits for `load` or an idle callback races it.
 * Nothing is fetched until a tool runs, so registering early costs nothing.
 *
 * SAME ORIGIN, NO DEPENDENCIES, NOTHING OUTSIDE THE SITE. A site with a strict CSP
 * (`script-src 'self'`, `connect-src 'self'`) runs this file and its fetches unchanged. The site
 * root comes from this script's own URL, so it holds wherever the site is mounted (`/`, or
 * `/<repo>/` behind a docs router), and every URL a tool is handed is checked against it: a tool
 * never reads or opens a page of anything else, which keeps `open_page` from becoming a redirect
 * to wherever an agent was told to go.
 */
(() => {
  "use strict";

  // One registration per document. Material's instant navigation keeps the document across
  // page changes, so a second copy of this script must find the first and stop.
  const FLAG = "__tremvokWebMcp";
  if (window[FLAG]) return;

  const contexts = [...new Set([document.modelContext, navigator.modelContext])].filter(
    (context) => Boolean(context) && typeof context.registerTool === "function",
  );
  // Read now: `document.currentScript` is only set while this script is running.
  const script = document.currentScript;
  if (contexts.length === 0 || !script || !script.src) return;

  // <root>assets/javascripts/webmcp.js, so the root is two directories up.
  const root = new URL("../../", script.src);
  const siteName = (script.dataset && script.dataset.site) || document.title || root.host;
  const controller = new AbortController();
  window[FLAG] = { root: root.href, controller };

  const LIMIT = 10;
  const MAX_LIMIT = 25;

  // -- Results --------------------------------------------------------------------------------
  //
  // The MCP tool-result shape, which the spec's own examples return and a browser serialises
  // as JSON either way. `isError` marks a refusal as the tool's answer, not a crash.

  const reply = (value) => ({
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
  });
  const refuse = (message) => ({ content: [{ type: "text", text: message }], isError: true });

  // -- URLs -----------------------------------------------------------------------------------

  const within = (url) => url.origin === root.origin && url.pathname.startsWith(root.pathname);

  function resolve(value) {
    try {
      const url = new URL(String(value), location.href);
      url.hash = "";
      return url;
    } catch {
      return null;
    }
  }

  /** A page's markdown copy: `setup/` -> `setup/index.md`, `setup.html` -> `setup.md`. */
  function twinOf(page) {
    const twin = new URL(page.href);
    twin.search = "";
    twin.hash = "";
    if (twin.pathname.endsWith(".md")) return twin;
    if (twin.pathname.endsWith("/")) twin.pathname += "index.md";
    else if (twin.pathname.endsWith(".html")) twin.pathname = `${twin.pathname.slice(0, -5)}.md`;
    else twin.pathname += "/index.md";
    return twin;
  }

  /** The page a markdown copy belongs to, which is the address to cite. */
  function pageOf(twin) {
    const page = new URL(twin.href);
    if (page.pathname.endsWith("/index.md")) page.pathname = page.pathname.slice(0, -"index.md".length);
    else if (page.pathname.endsWith(".md")) page.pathname = `${page.pathname.slice(0, -3)}.html`;
    return page;
  }

  // The SEO step links every page to its markdown copy. Where it did not run there are no
  // copies, and a URL to one would be a URL that 404s.
  const hasTwins = Boolean(document.querySelector('link[rel~="alternate"][type="text/markdown"]'));

  // -- Text -----------------------------------------------------------------------------------

  const NAMED = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

  /** Markup to text. The search index carries each section as HTML. */
  function plain(markup) {
    return String(markup)
      .replace(/<[^>]*>/g, " ")
      .replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (entity, name) => {
        if (name[0] !== "#") return NAMED[name.toLowerCase()] ?? entity;
        const code = name[1] === "x" || name[1] === "X" ? Number.parseInt(name.slice(2), 16) : Number(name.slice(1));
        return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
      })
      .replace(/\s+/g, " ")
      .trim();
  }

  const words = (value) => (String(value).toLowerCase().match(/[\p{L}\p{N}_]+/gu) || []).filter((w) => w.length > 1);

  function occurrences(haystack, needle, cap) {
    let count = 0;
    for (let at = haystack.indexOf(needle); at !== -1 && count < cap; at = haystack.indexOf(needle, at + needle.length)) {
      count += 1;
    }
    return count;
  }

  function snippet(body, terms) {
    const lower = body.toLowerCase();
    const at = Math.min(...terms.map((term) => lower.indexOf(term)).filter((i) => i >= 0), body.length);
    const start = Math.max(0, at - 80);
    const end = Math.min(body.length, start + 240);
    return `${start > 0 ? "\u2026" : ""}${body.slice(start, end).trim()}${end < body.length ? "\u2026" : ""}`;
  }

  // -- What the site publishes ----------------------------------------------------------------
  //
  // Read on first use and kept for the page's lifetime. A failed read is forgotten, so the next
  // call tries again rather than answering from a failure.

  let entries = null;

  /** MkDocs' own search index, built by the `search` plugin: every page and every section. */
  async function fromSearchIndex() {
    const response = await fetch(new URL("search/search_index.json", root));
    if (!response.ok) return null;
    const data = await response.json().catch(() => null);
    if (!data || !Array.isArray(data.docs)) return null;
    const titles = new Map();
    for (const doc of data.docs) {
      if (typeof doc.location === "string" && !doc.location.includes("#")) titles.set(doc.location, String(doc.title ?? ""));
    }
    return data.docs
      .filter((doc) => typeof doc.location === "string")
      .map((doc) => {
        const [page, anchor] = doc.location.split("#");
        const title = String(doc.title ?? "");
        const pageTitle = titles.get(page) ?? "";
        return {
          title: anchor && pageTitle && pageTitle !== title ? `${pageTitle}: ${title}` : title || pageTitle,
          url: new URL(doc.location, root).href,
          page: new URL(page, root).href,
          text: plain(doc.text ?? ""),
          isPage: !anchor,
        };
      });
  }

  /** llms.txt, for a site built without the search plugin: one line per page. */
  async function fromLlmsTxt() {
    const response = await fetch(new URL("llms.txt", root));
    if (!response.ok) return null;
    const found = [];
    for (const line of (await response.text()).split("\n")) {
      const match = /^- \[(.+?)\]\((\S+?)\)(?::\s*(.*))?$/.exec(line.trim());
      const link = match && resolve(match[2]);
      if (!link || !within(link)) continue;
      const page = pageOf(link).href;
      found.push({ title: match[1], url: page, page, text: match[3] ?? "", isPage: true });
    }
    return found.length > 0 ? found : null;
  }

  function loadEntries() {
    if (entries === null) {
      entries = (async () => (await fromSearchIndex()) ?? (await fromLlmsTxt()) ?? [])();
      entries.catch(() => {
        entries = null;
      });
    }
    return entries;
  }

  /** The sitemap, when there is neither: every page's address and nothing else. */
  async function fromSitemap() {
    const response = await fetch(new URL("sitemap.xml", root));
    if (!response.ok) return [];
    const xml = await response.text();
    return [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)]
      .map((match) => resolve(match[1].replace(/&amp;/g, "&")))
      .filter((url) => url && within(url))
      .map((url) => ({ title: "", url: url.href }));
  }

  // -- The tools ------------------------------------------------------------------------------

  async function searchDocs(input) {
    const query = String((input && input.query) || "").trim();
    const terms = [...new Set(words(query))];
    if (terms.length === 0) return refuse("search_docs needs a query with at least one word in it.");
    const limit = Math.min(Math.max(Number.parseInt(input.limit, 10) || LIMIT, 1), MAX_LIMIT);
    const scored = [];
    for (const entry of await loadEntries()) {
      const title = entry.title.toLowerCase();
      const body = entry.text.toLowerCase();
      let score = 0;
      let matched = 0;
      for (const term of terms) {
        const inTitle = title.includes(term);
        const hits = occurrences(body, term, 5);
        if (inTitle || hits > 0) matched += 1;
        score += (inTitle ? 10 : 0) + hits;
      }
      // Every word found beats any number of hits on some of them.
      if (matched > 0) scored.push({ entry, score: score + (matched === terms.length ? 1000 : 0) });
    }
    scored.sort((a, b) => b.score - a.score);
    const results = scored.slice(0, limit).map(({ entry }) => ({
      title: entry.title,
      url: entry.url,
      snippet: snippet(entry.text, terms),
    }));
    return reply({ site: siteName, query, results });
  }

  async function readPage(input, options) {
    const target = resolve((input && input.url) || location.href);
    if (!target || !within(target)) {
      return refuse(`read_page reads pages of ${siteName} only, under ${root.href}.`);
    }
    const signal = options && options.signal;
    try {
      const response = await fetch(twinOf(target), { headers: { accept: "text/markdown" }, signal });
      // A missing copy is the site's 404 page, and a host that rewrites unknown paths answers
      // with HTML: only a text response is the markdown.
      if (response.ok && !/html/i.test(response.headers.get("content-type") ?? "")) return reply(await response.text());
    } catch (error) {
      if (signal && signal.aborted) throw error;
    }
    const response = await fetch(target, { signal });
    if (!response.ok) return refuse(`${target.href} answered ${response.status}.`);
    const parsed = new DOMParser().parseFromString(await response.text(), "text/html");
    const region = parsed.querySelector("article") || parsed.querySelector("main") || parsed.body;
    if (!region) return reply("");
    // The permalink every heading carries is a pilcrow, not part of the heading.
    for (const link of region.querySelectorAll(".headerlink")) link.remove();
    return reply(region.textContent.replace(/\n\s*\n\s*\n+/g, "\n\n").trim());
  }

  async function listPages() {
    const pages = (await loadEntries()).filter((entry) => entry.isPage);
    const listed = pages.length > 0 ? pages : await fromSitemap();
    const seen = new Set();
    const result = [];
    for (const entry of listed) {
      if (seen.has(entry.url)) continue;
      seen.add(entry.url);
      const page = { title: entry.title, url: entry.url };
      if (hasTwins) page.markdown = twinOf(new URL(entry.url)).href;
      result.push(page);
    }
    return reply({ site: siteName, root: root.href, pages: result });
  }

  function openPage(input) {
    const target = resolve((input && input.url) || "");
    if (!(input && input.url) || !target || !within(target)) {
      return refuse(`open_page opens pages of ${siteName} only, under ${root.href}.`);
    }
    location.assign(target.href); // nosemgrep -- target was checked to lie inside this site's own root just above
    return reply(`Opening ${target.href}`);
  }

  const url = {
    type: "string",
    description: `A page of this site, absolute or relative to the page that is open, under ${root.href}.`,
  };
  const tools = [
    {
      name: "search_docs",
      title: `Search ${siteName}`,
      description: `Search the ${siteName} documentation. Returns the best-matching pages and sections, each with its URL and a snippet.`,
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "The words to look for." },
          limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, description: `How many results to return, ${LIMIT} by default.` },
        },
        required: ["query"],
      },
      annotations: { readOnlyHint: true },
      execute: searchDocs,
    },
    {
      name: "read_page",
      title: "Read a page as markdown",
      description: `Return a page of the ${siteName} documentation as markdown, the page that is open when no URL is given. Cite the page URL, not the markdown's.`,
      inputSchema: { type: "object", properties: { url } },
      annotations: { readOnlyHint: true },
      execute: readPage,
    },
    {
      name: "list_pages",
      title: `List the ${siteName} pages`,
      description: `List every page of the ${siteName} documentation with its title and URL${hasTwins ? ", and the URL of its markdown" : ""}.`,
      inputSchema: { type: "object", properties: {} },
      annotations: { readOnlyHint: true },
      execute: listPages,
    },
    {
      name: "open_page",
      title: "Open a page",
      description: `Navigate this tab to another page of the ${siteName} documentation.`,
      inputSchema: { type: "object", properties: { url }, required: ["url"] },
      execute: openPage,
    },
  ];

  for (const context of contexts) {
    for (const tool of tools) {
      try {
        const pending = context.registerTool(tool, { signal: controller.signal });
        if (pending && typeof pending.catch === "function") pending.catch(() => {});
      } catch {
        // A name another script on the page already holds, or a browser that refuses: that one
        // tool goes unregistered, and the page itself is unaffected.
      }
    }
  }

  // Unregistered when the document is discarded. A page kept in the back/forward cache keeps
  // its tools, because it comes back as the same document.
  addEventListener("pagehide", (event) => {
    if (!event.persisted) controller.abort();
  });
})();
