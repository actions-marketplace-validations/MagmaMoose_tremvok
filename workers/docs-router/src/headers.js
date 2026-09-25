/**
 * The headers every response on docs.magmamoose.com carries, and the corrections the router
 * makes to what the site Workers return.
 *
 * WHY HERE AND NOT IN EACH SITE WORKER. The site Workers are provisioned per repository by
 * MagmaMoose/admin from a template, and they return `env.ASSETS.fetch(request)` and nothing
 * else. A header policy there would be one copy per repository to keep in step, and the one
 * that lags is the one serving without HSTS. Every response on this host passes through this
 * Worker, so this is the one place a policy is actually a policy.
 *
 * NO CONTENT-SECURITY-POLICY ON THE SITES. MkDocs Material pages run inline scripts and load
 * Google Fonts and the MathJax and mermaid CDNs, so a strict policy would break them and a
 * loose one would only be decoration. The router's own documents get one, because the router
 * wrote every byte of them and knows exactly what they load.
 */

export const HOST_HEADERS = Object.freeze({
  "strict-transport-security": "max-age=63072000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  // SAMEORIGIN rather than DENY: a docs page may frame another page of its own site, and
  // nothing else on the web has a reason to frame any of them.
  "x-frame-options": "SAMEORIGIN",
  // Features no documentation page uses. Only names every browser that parses the header
  // recognises: an unrecognised one is logged to the console on every page view.
  "permissions-policy":
    "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()",
});

/** For a router document that loads nothing: plain text, XML, JSON, a redirect. */
export const DOCUMENT_CSP = "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'";

/**
 * The policy for the router's HTML pages, given the hash of the one inline stylesheet.
 *
 *   script-src   `'self'` admits the landing page's one script, /webmcp.js (the WebMCP tools,
 *                webmcp.js), and Cloudflare's same-origin injections (/cdn-cgi/). Nothing inline:
 *                the tools are a file rather than an inline block so that no hash has to track
 *                their source. static.cloudflareinsights.com is where Web Analytics loads its
 *                beacon from when it injects it.
 *   connect-src  Where that beacon reports: /cdn-cgi/rum on this host for a proxied site,
 *                cloudflareinsights.com otherwise (developers.cloudflare.com/web-analytics).
 *                `'self'` is also what the WebMCP tools fetch: each site's llms.txt and pages.
 *   style-src-attr  Cloudflare's AI Labyrinth injects a hidden link carrying an inline
 *                `style` attribute into every HTML response. Refusing it breaks nothing (the
 *                link is empty) but logs a CSP error to the console on every page view.
 *                This admits style attributes only: not `<style>` elements, not scripts.
 *   img-src      The favicon and touch icon are www.magmamoose.com's.
 */
export function pageCsp(styleHash) {
  return [
    "default-src 'none'",
    "script-src 'self' https://static.cloudflareinsights.com",
    `style-src '${styleHash}'`,
    "style-src-attr 'unsafe-inline'",
    "img-src 'self' https://www.magmamoose.com",
    "connect-src 'self' https://cloudflareinsights.com",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'",
  ].join("; ");
}

/** `sha256-<base64>` of a string, the form CSP hash sources take. */
export async function sha256Source(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return `sha256-${btoa(String.fromCharCode(...new Uint8Array(digest)))}`;
}

/** A strong ETag over the exact bytes served, so If-None-Match can answer 304. */
export async function etagOf(body) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `"${hex.slice(0, 32)}"`;
}

/**
 * RFC 9110 If-None-Match: `*`, or a list of tags compared weakly (a W/ prefix is ignored).
 * Weak comparison matters here beyond the letter of the RFC: Cloudflare weakens a strong
 * ETag when it rewrites an HTML response (Web Analytics, AI Labyrinth), so a browser
 * revalidating the landing page sends back the W/ form of the tag this Worker issued.
 */
export function matchesIfNoneMatch(header, etag) {
  if (!header) return false;
  const bare = (tag) => tag.trim().replace(/^W\//, "");
  return header.split(",").some((tag) => tag.trim() === "*" || bare(tag) === bare(etag));
}

/** Add a token to Vary without repeating one already there. */
export function appendVary(headers, token) {
  const current = headers.get("vary");
  if (!current) {
    headers.set("vary", token);
    return;
  }
  const tokens = current.split(",").map((t) => t.trim().toLowerCase());
  if (tokens.includes("*") || tokens.includes(token.toLowerCase())) return;
  headers.set("vary", `${current}, ${token}`);
}

/**
 * A document the router serves itself. ETag and If-None-Match on every one of them, so a
 * crawler re-reading robots.txt or the sitemap index gets a 304 rather than the same bytes.
 */
export async function document(request, body, { type, cache, csp = DOCUMENT_CSP, headers = {} }) {
  const etag = await etagOf(body);
  const all = {
    ...HOST_HEADERS,
    "content-security-policy": csp,
    "content-type": type,
    "cache-control": cache,
    etag,
    ...headers,
  };
  if (matchesIfNoneMatch(request.headers.get("if-none-match"), etag)) {
    return new Response(null, { status: 304, headers: all });
  }
  return new Response(request.method === "HEAD" ? null : body, { status: 200, headers: all });
}

/**
 * A redirect the router issues itself. `headers` adds to it (a Link, a Vary) but cannot
 * replace the security headers, the CSP, the caching or the Location.
 */
export function redirect(location, status = 301, cache = "public, max-age=3600", headers = {}) {
  return new Response(null, {
    status,
    headers: {
      ...HOST_HEADERS,
      ...headers,
      "content-security-policy": DOCUMENT_CSP,
      "cache-control": cache,
      location,
    },
  });
}

/** A site Worker that threw instead of answering. Not cached: the next request may succeed. */
export function badGateway() {
  return new Response("Bad Gateway: the documentation site did not answer.\n", {
    status: 502,
    headers: {
      ...HOST_HEADERS,
      "content-security-policy": DOCUMENT_CSP,
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

/** Anything but GET or HEAD on a path the router answers itself. */
export function methodNotAllowed() {
  return new Response("Method Not Allowed\n", {
    status: 405,
    headers: {
      ...HOST_HEADERS,
      "content-security-policy": DOCUMENT_CSP,
      "content-type": "text/plain; charset=utf-8",
      allow: "GET, HEAD",
    },
  });
}

/**
 * `.txt` and `.md` as UTF-8, whatever the assets router guessed. It serves `text/plain` with
 * no charset, and a client that does not assume UTF-8 (Python's, for one) turns every curly
 * quote in an llms.txt into mojibake. 2xx only: a missing file is answered with the site's
 * 404.html, and relabelling that as text would show a browser raw markup.
 */
const TEXT_TYPES = Object.freeze({
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
});

/**
 * A site's Agent Skills files are public metadata a browser-based client may read (the RFC asks
 * for CORS then), like the host's own index. `*` never carries credentials, so a private site's
 * copy stays behind Access for anything cross-origin.
 */
const SKILLS_PREFIX = "/.well-known/agent-skills/";

function extensionOf(path) {
  const match = /\.[a-z0-9]+$/i.exec(path);
  return match ? match[0].toLowerCase() : "";
}

/**
 * A site Worker's response, as the router returns it.
 *
 *   repo       the path segment the site is served under
 *   path       the path the site Worker was asked for (the prefix already stripped)
 *   pageUrl    for a path ending in /index.md, the page it is the markdown twin of
 *   varyAccept the path is a page that answers markdown to `Accept: text/markdown`
 */
export function decorateSiteResponse(response, { repo, path, pageUrl = null, varyAccept = false }) {
  const decorated = new Response(response.body, response);
  const headers = decorated.headers;
  for (const [name, value] of Object.entries(HOST_HEADERS)) headers.set(name, value);

  const ok = response.status >= 200 && response.status < 300;
  const type = TEXT_TYPES[extensionOf(path)];
  if (ok && type) headers.set("content-type", type);

  // A page's markdown twin is the same document in another format, so it names the page as
  // canonical. Without this, every index.md is a second crawlable copy of its page.
  if (ok && pageUrl) headers.append("link", `<${pageUrl}>; rel="canonical"`);

  if (varyAccept) appendVary(headers, "Accept");

  if (ok && path.startsWith(SKILLS_PREFIX)) headers.set("access-control-allow-origin", "*");

  // THE SITE WORKER'S REDIRECTS ARE RELATIVE TO ITS OWN ROOT. It was asked for `/setup`, so
  // the assets router's trailing-slash redirect says `Location: /setup/`, and a browser that
  // follows it lands on docs.magmamoose.com/setup/: the host's 404, with no hint the page
  // exists one segment over. The prefix this router stripped goes back on. Only a
  // path-absolute Location is touched; `//host/...` is another host, and a relative one
  // already resolves against the prefixed URL the browser asked for.
  const location = headers.get("location");
  if (location && location.startsWith("/") && !location.startsWith("//")) {
    headers.set("location", `/${repo}${location}`);
  }
  return decorated;
}

/**
 * A page answered as markdown: its index.md twin, labelled as markdown, varying on Accept,
 * and naming the page URL as canonical, since the markdown and the HTML are one document.
 */
export function markdownTwin(response, pageUrl) {
  const twin = new Response(response.body, response);
  const headers = twin.headers;
  for (const [name, value] of Object.entries(HOST_HEADERS)) headers.set(name, value);
  headers.set("content-type", "text/markdown; charset=utf-8");
  appendVary(headers, "Accept");
  headers.append("link", `<${pageUrl}>; rel="canonical"`);
  return twin;
}

/**
 * True when the FIRST media range of Accept is text/markdown. The first, not the best by
 * q-value: an agent asking for markdown puts it first, and a browser never does, so this
 * cannot turn a person's page into markdown by accident.
 */
export function prefersMarkdown(accept) {
  if (!accept) return false;
  const [range, ...params] = accept
    .split(",")[0]
    .split(";")
    .map((part) => part.trim().toLowerCase());
  if (range !== "text/markdown") return false;
  const q = params.find((param) => param.startsWith("q="));
  return !q || Number.parseFloat(q.slice(2)) > 0;
}
