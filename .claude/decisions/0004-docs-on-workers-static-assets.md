# 4. Docs sites move to Workers Static Assets behind a service-bound router

**Status:** accepted · **Date:** 2026-09-16 ·
**Implements:** [nievah ADR-0005 — One docs corpus, three MCP surfaces](https://github.com/MagmaMoose/nievah/blob/main/docs/adr/0005-docs-sites-and-mcp-surfaces.md) ·
**Relates to:** [0003 — Cloudflare Workers is a deployment target](0003-cloudflare-workers-target.md)

**Accepted.** The router Worker is classified as MagmaMoose org infrastructure rather than a
Tremvok hosted component; CLAUDE.md and AGENTS.md have been updated accordingly. The routing
table (open question 2) remains a starting set and grows as other repos are onboarded.

## Context

ADR-0005 in `nievah` makes `docs.magmamoose.com/<repo>/` the canonical address for every
documentation site in the fleet and assigns "the Workers Static Assets migration" to this
repository. Two of its four named traps are about not losing something in the move:
`require-access` must survive it, and a Wrangler binding is only real if a dry-run prints it.

Implementing it here runs into two things this repository has already decided.

**First, the thing being migrated *from* is not what the migration was described as.** There
is no Cloudflare Pages publishing path in Tremvok to migrate. It existed from `v1.0.0` through
`v1.0.20` — `deploy-cloudflare-pages.sh`, `docs-require-access`, `access_covers.py` — and
commit `83ebc48` ("One action, five deployment targets", #20) deleted all of it, which 0003
records and `docs/migration.md` documents as `require-access` **removed**. What the fleet's
docs sites actually publish to today is GitHub Pages, via `target: github-pages` and the
caller's own `actions/deploy-pages` job. So this is a GitHub Pages → Workers Static Assets
migration, and `require-access` is being **restored**, not preserved.

**Second, 0003 deferred `require-access` on purpose.** It said whether a preview URL belongs
behind Access "deserves its own decision rather than arriving as a leftover". This is that
decision, and the answer turns out to be narrower than the question: previews are not
involved at all, because these Workers have no preview destination.

## Decision

**A new target, `cloudflare-docs`.** The MkDocs build is shared with `github-pages` verbatim —
toolchain detection, the shape lint, markdownlint, the strict build — and only the publish
differs, which is the boundary every other target already sits on. `github-pages` is not
extended with a destination selector: v2 removed `docs-target` and `docs/migration.md` says
nothing replaces it, and a target named for where it publishes cannot also publish elsewhere.

**The router dispatches over a service binding, never an HTTP proxy.** This is the load-bearing
detail rather than a preference. An HTTP proxy needs a public origin hostname for every site,
which `workers_dev = false` exists org-wide to prevent; and proxying an Access-gated origin
requires the router to hold a service token, at which point Access is gating the *router*
rather than the user and `require-access` is checking a hostname nobody visits. With a service
binding there is no public origin and no token. The gate sits once, path-scoped, on
`docs.magmamoose.com`.

**Each site Worker has a `main`, and pays an invocation per asset request.** An assets-only
Worker is served straight off the edge and asset requests are not billed as invocations, which
is what `cloudflare-workers` recommends for a static site. It is not available here: a service
binding dispatches to a Worker's fetch handler, and `main` is what gives it one. The cost is
real and is the price of sharing one hostname by path.

**`require-access` returns as `cloudflare-docs-require-access`, and it fails closed.** The
check asks Cloudflare which Access applications exist and refuses to publish a private site
that none covers. Its three outcomes are never collapsed — covered, not covered, and *could
not tell* — because the failure that matters is a 403 from a token without `Access: Apps` read
being indistinguishable from an account with no applications. That is the same defect class as
the unreadable review list in `.claude/COMMON_MISTAKES.md`, and it publishes a private site to
the open internet while reporting that it checked.

**Every binding is verified by `wrangler deploy --dry-run` in CI**, and the check fails rather
than skips when Node is missing. A binding-verification job that silently skips is a required
check that never reports, which is the other gate failure this repository has been bitten by.

## Consequences

**What this costs.**

- **A second provider in the docs path.** GitHub Pages was free and operated by GitHub. This is
  a Cloudflare account, a stored `cloudflare-api-token` — a strictly weaker credential than the
  OIDC role assumption the AWS targets use, as 0003 already noted — and now an Access
  application whose existence the deploy depends on.
- **`github-pages` no longer owns an input of its own.** Every `pages-` input is shared with
  its sibling target. `tests/test_input_targets.py` encodes this explicitly rather than having
  the guard quietly weakened.
- **A per-request invocation for every asset**, as above.

**Open, and for a maintainer rather than an implementer:**

1. **Whose hosted component is the router?** `CLAUDE.md` says "Tremvok's own hosted components
   are AWS — the API is Lambda, not a Worker", and 0003 restated that as binding. A router
   Worker on `docs.magmamoose.com` is a Worker that somebody runs and pays for. The reading
   taken here is that it is **MagmaMoose org infrastructure, not a Tremvok hosted component**:
   0003 defines a hosted component as infrastructure *Tremvok itself* runs, and the router
   serves every repository's documentation, not Tremvok's backend. The source lives here
   because this repository is the docs toolchain. That reading is defensible and it is not
   obviously right — `MagmaMoose/admin` is the other candidate owner, and ADR-0005 already
   assigns the provisioning half of this work there. If the router belongs in `admin`,
   `workers/docs-router/` should move and this repository should keep only the target.
   Whichever way it goes, `CLAUDE.md`'s hard-constraint wording needs to say it, because a
   constraint that the code contradicts is what 0003 spent twenty releases paying for.

2. **The fleet's routing table is currently four repositories** — `tremvok`, `nievah`,
   `chargate`, `noctyr` — chosen because ADR-0005 names two of them and this session could see
   the other two. It is a starting set, not a survey. Every repository with a docs site needs a
   `[[services]]` block before its docs are reachable, and a repository that is missing gets a
   404 from the router rather than a broken build, so the omission is quiet.

**What this does not do.** Nothing here is applied to a real account. As in 0003, Wrangler runs
behind a bats recorder, and the only live command anything in this change set runs is
`wrangler deploy --dry-run`, which publishes nothing. The router and the site Workers are
configuration and source; deploying them is a separate, human act, and this PR must not merge
before the router exists and `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` are set — the
`site_url` change makes `docs.magmamoose.com/tremvok/` canonical the moment it lands.
