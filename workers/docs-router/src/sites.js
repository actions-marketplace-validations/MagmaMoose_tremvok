/**
 * Which documentation sites this router serves, and what each one says about itself.
 *
 * TWO QUESTIONS, TWO SOURCES, AND NEITHER IS A LIST IN THIS FILE.
 *
 *   - WHICH sites exist comes from `env`. Every service binding in wrangler.toml is a site,
 *     and wrangler.toml is the only list: a table here beside a `[[services]]` block there
 *     would be two places to add a repository, and missing one is a 404 that looks like a
 *     broken deploy.
 *   - WHAT a site is called, and its one-line summary, comes from that site's own
 *     `/llms.txt`, read over the same service binding. The docs build writes that file from
 *     the repository's `site_name` and `site_description` (scripts/gen_docs_index.py), so the
 *     root says what the repository says about itself, and a rename needs nothing here.
 *
 * A BOUND SITE IS NOT NECESSARILY A PUBLIC ONE. The private four are held out of the route
 * table today (see wrangler.toml), but each is meant to come back once an Access application
 * covers its path. Access gates PEOPLE at the edge. It does not gate this Worker, and a
 * service binding call never passes through it. So the day one of them is bound, reading its
 * llms.txt here would copy a private site's name and summary onto the public root, into
 * /llms.txt and into the sitemap index, past the gate that protects the site itself.
 * `PRIVATE_SITES` in wrangler.toml names them ahead of time: routed as normal, never listed,
 * never read.
 */

/** The one hostname every site is served on. wrangler.toml's route must agree (tested). */
export const ORIGIN = "https://docs.magmamoose.com";

/** `https://docs.magmamoose.com/<repo>/`, the address a site is canonical at (ADR-0005). */
export function siteUrl(repo) {
  return `${ORIGIN}/${repo}/`;
}

/**
 * `noctyr` -> NOCTYR, `oblivious-tls` -> OBLIVIOUS_TLS. Upper snake, because a binding name
 * is a JavaScript identifier on `env` and a hyphen is not one.
 *
 * Upper-casing is also what keeps a path segment off Object.prototype: every property there
 * is camel or lower case, so `/constructor/` looks up `env.CONSTRUCTOR`, which is nothing.
 */
export function bindingNameFor(segment) {
  return segment.toUpperCase().replace(/-/g, "_");
}

/** The inverse: the repository name, and so the path segment, a binding routes for. */
export function repoFor(bindingName) {
  return bindingName.toLowerCase().replace(/_/g, "-");
}

/** A service binding is anything on `env` that can take a request. Vars and arrays cannot. */
export function isService(value) {
  return Boolean(value) && typeof value.fetch === "function";
}

/** Every service binding present on env, as the repo names they route for. */
export function routableRepos(env) {
  return Object.entries(env)
    .filter(([, value]) => isService(value))
    .map(([name]) => repoFor(name))
    .sort();
}

/** `PRIVATE_SITES` from wrangler.toml, as a set of repo names. A JSON array; a string is tolerated. */
export function privateSites(env) {
  const declared = env.PRIVATE_SITES;
  let names = [];
  if (Array.isArray(declared)) {
    names = declared;
  } else if (typeof declared === "string") {
    names = declared.split(/[\s,]+/);
  }
  return new Set(names.map((name) => String(name).trim().toLowerCase()).filter(Boolean));
}

/**
 * The sites the root may name: routable, and not private. Every listing surface (the landing
 * page, /llms.txt, /sitemap.xml, the 404 page) goes through this and nothing else, so there
 * is one place where "may this site be listed" is decided.
 */
export function listedRepos(env) {
  const hidden = privateSites(env);
  return routableRepos(env).filter((repo) => !hidden.has(repo));
}

// ── Reading a site's llms.txt ─────────────────────────────────────────────────

const TITLE_MAX = 80;
const SUMMARY_MAX = 300;

/**
 * Only the head of the file is read. The title and summary are its first lines, and a site
 * whose llms.txt grew to megabytes must not cost the root megabytes of decoding.
 */
const HEAD_CHARS = 8192;

function clean(value, max) {
  const text = value.replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
}

/**
 * The `# Title` and the first `> summary` of an llms.txt (llmstxt.org), or nulls.
 *
 * The first non-empty line has to be the H1. Anything else is not an llms.txt, and the case
 * that matters is an HTML page answered with a 200: reading "<!doctype html>" as a title
 * would put markup on the landing page. The summary is the first blockquote line before the
 * first `##` section, which is where the format puts it.
 */
export function parseLlmsTxt(text) {
  const none = { title: null, summary: null };
  let title = null;
  for (const raw of String(text).split("\n")) {
    const line = raw.trim();
    if (title === null) {
      if (line === "") continue;
      if (!line.startsWith("# ")) return none;
      title = clean(line.slice(2), TITLE_MAX);
      if (!title) return none;
      continue;
    }
    if (line.startsWith("## ")) break;
    if (line.startsWith(">")) {
      return { title, summary: clean(line.slice(1), SUMMARY_MAX) || null };
    }
  }
  return { title, summary: null };
}

/**
 * At most about `limit` characters of a body, and whether that was all of it. Past the limit
 * the rest is cancelled rather than read: a site's file must not cost the root more than it
 * needs, however large the file grew.
 */
export async function readUpTo(response, limit) {
  if (!response.body) return { text: "", complete: true };
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let done = false;
  while (!done && text.length < limit) {
    const chunk = await reader.read();
    done = chunk.done;
    if (chunk.value) text += decoder.decode(chunk.value, { stream: true });
  }
  if (!done) {
    // The rest of the file is not needed. Cancelling says so instead of leaving it buffered.
    try {
      await reader.cancel();
    } catch {
      // Nothing to do: the head is already in hand.
    }
  }
  return { text, complete: done };
}

async function readHead(response, limit) {
  return (await readUpTo(response, limit)).text;
}

/** How a site is listed when its llms.txt cannot be read: by its repository name, not dropped. */
function undescribed(repo) {
  return { repo, title: repo, summary: null, described: false };
}

async function describe(service, repo, origin, timeoutMs) {
  try {
    const init = { headers: { accept: "text/plain" } };
    if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
      // A site Worker that hangs must not hang the root with it.
      init.signal = AbortSignal.timeout(timeoutMs);
    }
    const response = await service.fetch(new Request(new URL("/llms.txt", origin), init));
    if (!response.ok) {
      await response.body?.cancel();
      return undescribed(repo);
    }
    const { title, summary } = parseLlmsTxt(await readHead(response, HEAD_CHARS));
    return title ? { repo, title, summary, described: true } : undescribed(repo);
  } catch {
    return undescribed(repo);
  }
}

// ── The per-isolate cache ─────────────────────────────────────────────────────
//
// A title changes when someone edits `site_name` and the site redeploys, so reading every
// site's llms.txt on every request would buy nothing but invocations: each read is a site
// Worker request against the account's daily allowance. Five minutes per isolate keeps the
// root within the Free plan by a wide margin and a rename visible within minutes.
//
// RESOLVED VALUES ONLY, NEVER AN IN-FLIGHT PROMISE. Sharing a pending fetch between two
// requests ties the second to the first's I/O context, and the Workers runtime cancels that
// I/O when the first request ends (its client hung up, say), which leaves the second waiting
// on something that will never settle. Two cold requests at once each read the file; that
// costs one extra invocation and is the whole price of not having that failure.
//
// NOT caches.default. The reads are I/O, not CPU (parsing two lines is microseconds), and a
// cross-isolate cache would hold a degraded page for its full TTL after a site's brief
// failure. Here a failure is retried after thirty seconds, and a site that was described
// before keeps its last good title and summary in the meantime.

export const DESCRIBED_TTL_MS = 5 * 60 * 1000;
export const RETRY_TTL_MS = 30 * 1000;
export const LOOKUP_TIMEOUT_MS = 2000;

/**
 * A request may invoke at most 32 Workers, and every service binding call is one of them
 * (developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings, "Limits"); the
 * 33rd throws. The router is the first. So one request reads at most this many llms.txt
 * files, and a site past the cap is listed by its name (or its cached description) rather
 * than taking the whole page down the day the fleet outgrows the limit.
 */
export const MAX_LOOKUPS_PER_REQUEST = 24;

const memo = new Map();

/** Forget every cached description. For tests. */
export function forgetSites() {
  memo.clear();
}

/**
 * Title and summary for each repo, in order. Never rejects: a site that cannot be read is
 * listed under its repository name.
 */
export async function describeSites(env, repos, origin, { timeoutMs = LOOKUP_TIMEOUT_MS } = {}) {
  const now = Date.now();
  let budget = MAX_LOOKUPS_PER_REQUEST;
  return Promise.all(
    repos.map(async (repo) => {
      const hit = memo.get(repo);
      if (hit && hit.expires > now) return hit.site;
      if (budget === 0) return hit ? hit.site : undescribed(repo);
      budget -= 1;
      const fresh = await describe(env[bindingNameFor(repo)], repo, origin, timeoutMs);
      // A read that failed does not overwrite a description that was good: stale beats blank.
      const site = fresh.described || !hit ? fresh : hit.site;
      memo.set(repo, {
        site,
        expires: Date.now() + (fresh.described ? DESCRIBED_TTL_MS : RETRY_TTL_MS),
      });
      return site;
    }),
  );
}
