/**
 * docs.magmamoose.com: the router.
 *
 * One hostname, N documentation sites. Cloudflare will not let two Workers share a hostname
 * by path, so this Worker owns `docs.magmamoose.com/*` and dispatches `/<repo>/...` to that
 * repository's own docs Worker. The host root is its own (root.js): the landing page,
 * /llms.txt, /sitemap.xml, /robots.txt, security.txt and the discovery documents.
 *
 * IT DISPATCHES OVER A SERVICE BINDING, NOT AN HTTP PROXY, and per ADR-0005 that is the
 * load-bearing detail rather than an implementation preference:
 *
 *   - An HTTP proxy needs a public origin hostname for every site. `workers_dev = false`
 *     exists across the org precisely to prevent those from existing.
 *   - Proxying an Access-gated origin requires this router to hold a service token. At that
 *     point Access is no longer gating the *user* (the router is), and `require-access` is
 *     checking a hostname nobody visits.
 *
 * With a service binding there is no public origin to gate and no token to hold. The gate
 * sits once, path-scoped, on this hostname.
 *
 * `env.<BINDING>.fetch()` is an in-process dispatch to another Worker on Cloudflare's
 * network. It never leaves as an HTTP request, so there is nothing on the wire to
 * authenticate and no second hostname to protect. The same fact is why the root must not
 * describe a private site (sites.js): Access never sees these calls.
 *
 * EVERY RESPONSE LEAVES THROUGH headers.js, the router's own and the site Workers' alike, so
 * the host has one header policy rather than one per repository.
 */

import {
  badGateway,
  decorateSiteResponse,
  markdownTwin,
  prefersMarkdown,
  redirect,
} from "./headers.js";
import { notFound, rootHandler } from "./root.js";
import { ORIGIN, bindingNameFor, isService, repoFor } from "./sites.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url); // nosemgrep: ajinabraham.njsscan.redirect.open_redirect.express_open_redirect -- every redirect below is path-absolute on this host (a single "/" and then a routed site name), so none can leave docs.magmamoose.com
    const own = rootHandler(url.pathname);
    if (own) return own(request, env);

    const segments = url.pathname.split("/").filter(Boolean);
    if (segments.length === 0) {
      // `//` and friends, where URL normalization did not already merge the slashes.
      return redirect(`/${url.search}`);
    }

    const [repo, ...rest] = segments;
    const binding = bindingNameFor(repo);
    const service = env[binding];
    if (!isService(service)) return notFound(env);

    // ONE PATH PER PAGE, AND IT IS THE ONLY ONE A SITE WORKER EVER SEES. The binding lookup
    // is case-insensitive and treats `_` as `-`, and empty segments are dropped, so
    // `/Tremvok//setup` would otherwise serve the same page as `/tremvok/setup`. That is
    // duplicate content for a crawler and, once a private site is bound, a second spelling
    // of its path for Access to match or miss. A 301 to the canonical spelling means the
    // path an Access application is written for is the only one that reaches the site.
    //
    // A site root always takes its trailing slash: `/tremvok` and `/tremvok/` are different
    // requests to an assets router, and relative links in the page only resolve against the
    // second. Without it every asset on the landing page of every site 404s.
    const site = repoFor(binding);
    const trailing = rest.length === 0 || url.pathname.endsWith("/");
    const canonical = `/${[site, ...rest].join("/")}${trailing ? "/" : ""}`;
    if (canonical !== url.pathname) return redirect(`${canonical}${url.search}`);

    // `/tremvok/setup/` must reach the site Worker as `/setup/`: its assets are laid out
    // from ITS root, and every repo's build is identical in that respect. Stripping here
    // rather than in each site Worker is what keeps the site Worker generic: one template,
    // no per-repo code.
    const inner = new URL(url);
    inner.pathname = `/${rest.join("/")}${rest.length > 0 && trailing ? "/" : ""}`;

    const readable = request.method === "GET" || request.method === "HEAD";
    const page = readable && url.pathname.endsWith("/");
    const pageUrl = `${ORIGIN}${url.pathname}`;

    // MARKDOWN FOR AN AGENT THAT ASKS FOR IT FIRST. The docs build writes every page's markdown
    // beside it as `<page>/index.md`. A zone rule could rewrite to that path but could not
    // fall back when a site has not published its twins yet; this can. The twin is only
    // served when it is actually there: a 304 is its ETag matching, anything else is the
    // HTML page as though markdown had not been asked for.
    if (page && prefersMarkdown(request.headers.get("accept"))) {
      const twin = new URL(inner);
      twin.pathname = `${inner.pathname}index.md`;
      try {
        const markdown = await service.fetch(new Request(twin, request));
        if (markdown.status === 200 || markdown.status === 304) return markdownTwin(markdown, pageUrl);
        if (markdown.body) await markdown.body.cancel().catch(() => {});
      } catch {
        // No twin to be had: the page itself is the answer.
      }
    }

    // A new Request rather than passing `request` through: the URL is what changed, and the
    // method, headers and body have to survive unaltered.
    let response;
    try {
      response = await service.fetch(new Request(inner, request));
    } catch (error) {
      // A site Worker that throws would otherwise surface as Cloudflare's own error page,
      // which carries none of the host's headers and says nothing about which site failed.
      console.error("docs-router: a site Worker did not answer", { site, error: String(error) });
      return badGateway();
    }
    const twinOf = inner.pathname.endsWith("/index.md")
      ? `${ORIGIN}/${site}${inner.pathname.slice(0, -"index.md".length)}`
      : null;
    return decorateSiteResponse(response, {
      repo: site,
      path: inner.pathname,
      pageUrl: twinOf,
      varyAccept: page,
    });
  },
};
