/**
 * One repository's documentation site, as a Worker with Static Assets.
 *
 * WHY THERE IS A SCRIPT HERE AT ALL. An assets-only Worker — `[assets]` with no `main` — is
 * served straight off the edge with no code in the request path, which is cheaper and is what
 * `target: cloudflare-workers` recommends for an ordinary static site. It is NOT what this
 * needs: these Workers are never reached over HTTP. They are reached through a service
 * binding from the router on docs.magmamoose.com, and a service binding dispatches to a
 * Worker's fetch handler. `main` is what gives it one.
 *
 * The cost is honest and worth naming: every asset request is now a Worker invocation rather
 * than a free static-asset hit. That is the price of the hostname being shared by path, which
 * is the thing ADR-0005 decided to buy.
 *
 * Nothing here is per-repository. The whole configuration is `[assets].directory` in
 * wrangler.toml, so every docs site in the fleet ships this same file.
 */

export default {
  async fetch(request, env) {
    // The router has already stripped the `/<repo>` prefix, so the path that arrives is the
    // one the built site was laid out from. `env.ASSETS.fetch` applies the asset router:
    // directory URLs, index.html, and the not_found_handling configured in wrangler.toml.
    return env.ASSETS.fetch(request);
  },
};
