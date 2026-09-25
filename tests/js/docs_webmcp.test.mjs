/**
 * The WebMCP script every docs site gets (scripts/docs_webmcp.js), run as a browser would run
 * it: the file's own bytes, in a context holding nothing but what a page gives a script. A
 * fake site answers its fetches, and a fake model context records what registers.
 *
 * Run with `node --test tests/js/docs_webmcp.test.mjs`, or through pytest
 * (tests/test_docs_webmcp.py), which is how CI runs it.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../scripts/docs_webmcp.js", import.meta.url), "utf8");
const ROOT = "https://docs.example.test/widget/";
const SCRIPT = `${ROOT}assets/javascripts/webmcp.js?v=abc123`;

const SEARCH_INDEX = {
  config: { lang: ["en"] },
  docs: [
    { location: "", title: "Widget", text: "<p>Widget does one thing well.</p>" },
    { location: "setup/", title: "Setting Widget up", text: "<p>Install the widget with <code>pip</code>.</p>" },
    {
      location: "setup/#rolling-back",
      title: "Rolling back",
      text: "<p>Revert the commit &amp; push again. The deploy rolls back.</p>",
    },
    { location: "guides/deploy/", title: "Deploying", text: "<p>A deploy is one push to the default branch.</p>" },
  ],
};

const LLMS_TXT = [
  "# Widget",
  "",
  "> Widget does one thing well.",
  "",
  "## Docs",
  "",
  `- [Widget](${ROOT}index.md): Widget does one thing well.`,
  `- [Setting Widget up](${ROOT}setup/index.md): install the widget`,
  `- [Elsewhere](https://elsewhere.example/x/index.md): not this site`,
  "",
].join("\n");

/** A site that serves `files` (absolute URL -> body, or { status, body, type }). */
function fakeSite(files) {
  const fetched = [];
  const fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    fetched.push({ url: url.href, accept: init.headers?.accept ?? null });
    const file = files[url.href];
    if (file === undefined) {
      return new Response("<!doctype html><title>404</title>", { status: 404, headers: { "content-type": "text/html" } });
    }
    if (typeof file === "string") return new Response(file, { headers: { "content-type": "text/plain" } });
    return new Response(file.body, { status: file.status ?? 200, headers: { "content-type": file.type ?? "text/plain" } });
  };
  return { fetch, fetched };
}

/** The characters outside tags, as a parsed element's textContent would give them. */
function textOf(html) {
  let text = "";
  let inTag = false;
  for (const character of html) {
    if (character === "<") inTag = true;
    else if (character === ">") inTag = false;
    else if (!inTag) text += character;
  }
  return text;
}

/** Enough of DOMParser for the fallback: an <article>'s text, and its headerlinks to remove. */
class FakeDOMParser {
  parseFromString(markup) {
    const element = (html) => {
      const node = {
        html,
        get textContent() {
          return textOf(node.html);
        },
        querySelectorAll: (selector) =>
          selector === ".headerlink"
            ? [...node.html.matchAll(/<a class="headerlink"[^>]*>[^<]*<\/a>/g)].map((m) => ({
                remove: () => {
                  node.html = node.html.replace(m[0], "");
                },
              }))
            : [],
      };
      return node;
    };
    const article = /<article[^>]*>([\s\S]*?)<\/article>/.exec(markup);
    return {
      querySelector: (selector) => (selector === "article" && article ? element(article[1]) : null),
      body: element(markup),
    };
  }
}

function load({
  navigatorContext,
  documentContext,
  files = {},
  page = `${ROOT}setup/`,
  twins = true,
  currentScript = { src: SCRIPT, dataset: { site: "Widget" } },
} = {}) {
  const { fetch, fetched } = fakeSite(files);
  const listeners = {};
  const assigned = [];
  const context = {
    URL,
    AbortController,
    DOMParser: FakeDOMParser,
    fetch,
    location: { href: page, origin: new URL(page).origin, assign: (url) => assigned.push(String(url)) },
    document: {
      modelContext: documentContext,
      title: "Setting Widget up - Widget",
      currentScript,
      querySelector: (selector) => (twins && selector.includes('type="text/markdown"') ? {} : null),
    },
    navigator: navigatorContext === undefined ? {} : { modelContext: navigatorContext },
    addEventListener: (type, listener) => {
      listeners[type] = listener;
    },
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(SOURCE, context);
  return { context, listeners, assigned, fetched };
}

/** A model context shaped like the spec's: a second tool of the same name is refused. */
function modelContext() {
  const tools = [];
  return {
    tools,
    registerTool(tool, options) {
      if (tools.some((t) => t.tool.name === tool.name)) return Promise.reject(new Error("InvalidStateError"));
      tools.push({ tool, options });
      return Promise.resolve();
    },
  };
}

async function call(context, name, input) {
  const found = context.tools.find((t) => t.tool.name === name);
  assert.ok(found, `${name} was not registered`);
  const result = await found.tool.execute(input, { signal: new AbortController().signal });
  const text = result.content[0].text;
  let value = text;
  try {
    value = JSON.parse(text);
  } catch {
    // markdown or prose, not JSON
  }
  return { result, value };
}

const SITE = {
  [`${ROOT}search/search_index.json`]: { body: JSON.stringify(SEARCH_INDEX), type: "application/json" },
  [`${ROOT}setup/index.md`]: { body: "# Setting Widget up\n\n> Markdown source of the page.\n", type: "text/markdown" },
  [`${ROOT}llms.txt`]: LLMS_TXT,
};

describe("registration", () => {
  test("registers four tools with navigator.modelContext on load, each with a schema", () => {
    const context = modelContext();
    load({ navigatorContext: context });
    assert.deepEqual(
      context.tools.map((t) => t.tool.name),
      ["search_docs", "read_page", "list_pages", "open_page"],
    );
    for (const { tool, options } of context.tools) {
      assert.match(tool.description, /Widget/, tool.name);
      assert.equal(tool.inputSchema.type, "object", tool.name);
      assert.equal(typeof tool.execute, "function", tool.name);
      assert.ok(options.signal instanceof AbortSignal, `${tool.name} cannot be unregistered`);
    }
    const readOnly = context.tools.filter((t) => t.tool.annotations?.readOnlyHint).map((t) => t.tool.name);
    assert.deepEqual(readOnly, ["search_docs", "read_page", "list_pages"]);
  });

  test("uses document.modelContext too, and an object that is both only once", () => {
    const both = modelContext();
    load({ navigatorContext: both, documentContext: both });
    assert.equal(both.tools.length, 4);
    const onDocument = modelContext();
    const onNavigator = modelContext();
    load({ navigatorContext: onNavigator, documentContext: onDocument });
    assert.equal(onDocument.tools.length, 4);
    assert.equal(onNavigator.tools.length, 4);
  });

  test("with no model context does nothing at all, and defines none", () => {
    const { context, listeners, fetched } = load();
    assert.equal(context.navigator.modelContext, undefined);
    assert.equal(context.document.modelContext, undefined);
    assert.equal(context.__tremvokWebMcp, undefined);
    assert.deepEqual(Object.keys(listeners), []);
    assert.deepEqual(fetched, []);
  });

  test("with no script URL to find the site from, registers nothing", () => {
    const context = modelContext();
    load({ navigatorContext: context, currentScript: null });
    assert.equal(context.tools.length, 0);
  });

  test("registers once per document, however many times the script runs", () => {
    const context = modelContext();
    const { context: page } = load({ navigatorContext: context });
    vm.runInContext(SOURCE, page);
    assert.equal(context.tools.length, 4);
  });

  test("finds the site root two directories above itself, wherever the site is mounted", () => {
    const context = modelContext();
    const { context: page } = load({
      navigatorContext: context,
      page: "https://docs.example.test/setup/",
      currentScript: { src: "https://docs.example.test/assets/javascripts/webmcp.js?v=1", dataset: {} },
    });
    assert.equal(page.__tremvokWebMcp.root, "https://docs.example.test/");
    const { context: mounted } = load({ navigatorContext: modelContext() });
    assert.equal(mounted.__tremvokWebMcp.root, ROOT);
  });

  test("fetches nothing until a tool runs", () => {
    const { fetched } = load({ navigatorContext: modelContext(), files: SITE });
    assert.deepEqual(fetched, []);
  });

  test("pagehide unregisters the tools, unless the page is kept for back and forward", () => {
    const context = modelContext();
    const { listeners } = load({ navigatorContext: context });
    const { signal } = context.tools[0].options;
    listeners.pagehide({ persisted: true });
    assert.equal(signal.aborted, false);
    listeners.pagehide({ persisted: false });
    assert.equal(signal.aborted, true);
  });
});

describe("search_docs", () => {
  test("searches MkDocs' own index and puts pages matching every word first", async () => {
    const context = modelContext();
    load({ navigatorContext: context, files: SITE });
    const { value } = await call(context, "search_docs", { query: "deploy rolls back" });
    assert.equal(value.site, "Widget");
    assert.deepEqual(value.results[0], {
      title: "Setting Widget up: Rolling back",
      url: `${ROOT}setup/#rolling-back`,
      snippet: "Revert the commit & push again. The deploy rolls back.",
    });
    assert.deepEqual(value.results.map((r) => r.url), [`${ROOT}setup/#rolling-back`, `${ROOT}guides/deploy/`]);
  });

  test("honours a limit, and refuses a query with no words in it", async () => {
    const context = modelContext();
    load({ navigatorContext: context, files: SITE });
    const { value } = await call(context, "search_docs", { query: "widget", limit: 1 });
    assert.equal(value.results.length, 1);
    for (const query of ["", "  ", "!"]) {
      assert.equal((await call(context, "search_docs", { query })).result.isError, true, JSON.stringify(query));
    }
  });

  test("reads the index once, and again after a failure", async () => {
    let healthy = false;
    const files = { ...SITE };
    const context = modelContext();
    const { context: page, fetched } = load({ navigatorContext: context, files });
    page.fetch = async (input) => {
      fetched.push({ url: String(input) });
      if (!healthy) throw new Error("offline");
      return new Response(JSON.stringify(SEARCH_INDEX));
    };
    await assert.rejects(call(context, "search_docs", { query: "widget" }));
    healthy = true;
    await call(context, "search_docs", { query: "widget" });
    await call(context, "search_docs", { query: "deploy" });
    assert.equal(fetched.length, 2, "the index was not re-read after a failure, or was read twice");
  });

  test("falls back to llms.txt for a site built without the search plugin", async () => {
    const context = modelContext();
    load({ navigatorContext: context, files: { [`${ROOT}llms.txt`]: LLMS_TXT } });
    const { value } = await call(context, "search_docs", { query: "install" });
    assert.deepEqual(value.results.map((r) => r.url), [`${ROOT}setup/`]);
  });
});

describe("read_page", () => {
  test("answers with the page's markdown copy, the open page by default", async () => {
    const context = modelContext();
    const { fetched } = load({ navigatorContext: context, files: SITE });
    const { value } = await call(context, "read_page", {});
    assert.equal(value, "# Setting Widget up\n\n> Markdown source of the page.\n");
    assert.deepEqual(fetched.at(-1), { url: `${ROOT}setup/index.md`, accept: "text/markdown" });
    const explicit = await call(context, "read_page", { url: `${ROOT}setup/#rolling-back` });
    assert.equal(explicit.value, value);
  });

  test("reads the page's own text when it has no markdown copy", async () => {
    const context = modelContext();
    load({
      navigatorContext: context,
      files: {
        [`${ROOT}guides/deploy/`]: {
          body: '<html><nav>Menu</nav><article><h1>Deploying<a class="headerlink" href="#x">\u00b6</a></h1>\n\n\n\n<p>One push.</p></article></html>',
          type: "text/html",
        },
      },
    });
    const { value } = await call(context, "read_page", { url: "../guides/deploy/" });
    assert.equal(value, "Deploying\n\nOne push.");
  });

  test("does not take an HTML answer for the markdown", async () => {
    const context = modelContext();
    load({
      navigatorContext: context,
      files: {
        [`${ROOT}setup/index.md`]: { body: "<!doctype html><p>app shell</p>", type: "text/html" },
        [`${ROOT}setup/`]: { body: "<article>Setting Widget up</article>", type: "text/html" },
      },
    });
    const { value } = await call(context, "read_page", {});
    assert.equal(value, "Setting Widget up");
  });

  test("reads this site only", async () => {
    const context = modelContext();
    const { fetched } = load({ navigatorContext: context, files: SITE });
    for (const url of ["https://elsewhere.example/widget/setup/", "https://docs.example.test/other-site/", "javascript:alert(1)"]) {
      assert.equal((await call(context, "read_page", { url })).result.isError, true, url);
    }
    assert.deepEqual(fetched, []);
  });
});

describe("list_pages", () => {
  test("lists every page once, with its markdown when the site publishes copies", async () => {
    const context = modelContext();
    load({ navigatorContext: context, files: SITE });
    const { value } = await call(context, "list_pages", {});
    assert.equal(value.root, ROOT);
    assert.deepEqual(value.pages, [
      { title: "Widget", url: ROOT, markdown: `${ROOT}index.md` },
      { title: "Setting Widget up", url: `${ROOT}setup/`, markdown: `${ROOT}setup/index.md` },
      { title: "Deploying", url: `${ROOT}guides/deploy/`, markdown: `${ROOT}guides/deploy/index.md` },
    ]);
  });

  test("names no markdown URL on a site without copies", async () => {
    const context = modelContext();
    load({ navigatorContext: context, files: SITE, twins: false });
    const { value } = await call(context, "list_pages", {});
    assert.ok(value.pages.every((page) => !("markdown" in page)));
    assert.doesNotMatch(context.tools.find((t) => t.tool.name === "list_pages").tool.description, /markdown/);
  });

  test("falls back to the sitemap, and keeps to this site", async () => {
    const context = modelContext();
    const sitemap = [
      '<?xml version="1.0" encoding="UTF-8"?><urlset>',
      `<url><loc>${ROOT}</loc></url><url><loc>${ROOT}setup/</loc></url>`,
      "<url><loc>https://elsewhere.example/</loc></url></urlset>",
    ].join("");
    load({ navigatorContext: context, files: { [`${ROOT}sitemap.xml`]: sitemap }, twins: false });
    const { value } = await call(context, "list_pages", {});
    assert.deepEqual(value.pages, [
      { title: "", url: ROOT },
      { title: "", url: `${ROOT}setup/` },
    ]);
  });
});

describe("open_page", () => {
  test("opens a page of this site and nothing else", async () => {
    const context = modelContext();
    const { assigned } = load({ navigatorContext: context });
    const opened = await call(context, "open_page", { url: `${ROOT}guides/deploy/` });
    assert.equal(opened.value, `Opening ${ROOT}guides/deploy/`);
    for (const url of ["https://elsewhere.example/", "/other-site/", "", undefined]) {
      assert.equal((await call(context, "open_page", { url })).result.isError, true, String(url));
    }
    assert.deepEqual(assigned, [`${ROOT}guides/deploy/`]);
  });
});
