# Roadmap

<!-- sources: README.md, action.yml -->

Tremvok's scope is **deployment orchestration and notification**: the deploy-side
counterpart to [Diatreme](https://github.com/MagmaMoose/diatreme). One action covering
several deployment targets, not a family of narrow ones.

Status here is the single source; if a claim about maturity appears anywhere else in this
repo, it is wrong.

## Shipped

- **`target: github-pages`**: detect the toolchain, build the MkDocs site strictly, stage the
  Pages artifact for your deploy job, and verify the published URL answers. A pull request
  builds without staging, because one site with no preview destination is what `mode: preview`
  already means here.
- **`target: cloudflare-docs`**: the same strict MkDocs build as `github-pages`, published to
  Cloudflare Workers Static Assets instead. The site Worker has no route and no workers.dev
  URL; a router Worker on `docs.magmamoose.com` reaches it over a service binding, so one
  hostname serves every repository by path and Cloudflare Access gates the person visiting
  rather than the router. `cloudflare-docs-require-access` refuses to publish a private site
  that no Access application covers, and treats "could not tell" as a refusal. The same build
  emits the **docs corpus** (`llms.txt`, `llms-full.txt` and a search index) and, with a
  bucket named, publishes the index to R2 as `index/<repo>.json` after the site deploys, so a
  fleet of docs sites is one corpus written at build time rather than crawled afterwards. A
  repository that is a house tool ships a `capability.json` to `capability/<repo>.json` in the
  same bucket, validated against the MCP's schema on every run: that is what lets an agent be
  told "no house tool does this" rather than "nothing was found".
- **`target: s3-cloudfront`**: sync a built static site with per-class cache headers,
  invalidate CloudFront, previews under their own key prefix. Refuses to sync an empty
  artifact directory.
- **`target: lambda-zip`**: immutable S3 keys, published versions, the alias moved only on
  a deploy, and the deployed `CodeSha256` verified against the local artifact.
- **`target: terragrunt`**: discover, plan, gate on an independent approval, apply; a
  rolling pull-request comment with redacted plan excerpts, and a check run that makes
  apply-before-merge enforceable. Replaces Atlantis and its stored IAM credential.
- **`target: ansible`**: pinned Ansible, galaxy requirements, a playbook run over SSH with
  keys that cannot reach a log, check mode by default on a pull request, and a second
  check-mode run that proves the playbook converged.
- **`target: cloudflare-workers`**: a Worker and its static assets published with a pinned
  Wrangler. A push deploys; a pull request runs `versions upload --preview-alias pr-<n>`, so
  the preview has its own URL and takes no production traffic. The Wrangler config keeps
  owning the asset directory, the routes and 404 handling. Refuses to publish an empty asset
  directory.
- **Post-deploy verification**, **notifications** (sticky pull-request comment, Slack,
  Teams), and the **deployment-record API**.

## The entry-point rule, reversed

This page used to say that additional targets would get their own entry point rather than a
mode flag, because "a `job:` enum where most values error is a listing that cannot say what
it does". **That position is reversed**, and one action now carries every target.

The objection was right about the failure mode and wrong about the cause. A target enum
becomes a listing that cannot describe itself when the inputs that do not apply to the
selected target are *silently ignored*. The listing then documents an input surface that
does nothing for most callers. So the build removes the silence:

- **Every input is validated against the selected target.** An input that does not apply is
  a hard error naming the target, raised before the checkout. `target: ansible` with
  `s3-bucket` set is a mistake, and it is reported as one, with every other mistake in the
  same run.
- **Applicability is derived, not maintained.** `scripts/gen_input_targets.py` reads it out
  of the input descriptions in `action.yml` into the map the runtime validator uses, so the
  documentation and the check cannot disagree.
- **Input names carry their target**: `pages-`, `s3-`, `cloudfront-`, `lambda-`,
  `terragrunt-`, `ansible-`, `cloudflare-`, with `aws-` for what the AWS targets share and no
  prefix for what everything shares.

What the split cost was worse than what it bought: three entry points meant three
Marketplace-facing surfaces, an `examples/` directory pointing at the wrong one, and a
README, a roadmap and a repository description that each described a different product.

## Next

- **Rollback as a first-class mode.** `mode: rollback` resolves today but no target
  implements re-publishing a previous version. Deployment history exists to make it
  possible; wiring it is the remaining work.
- **Verifying a preview without pasting its URL in.** `verify-url` is a fixed input, so the
  per-run URL a Workers preview produces (the `url` output) reaches the comment, the webhooks
  and the deployment record, but nothing curls it. Feeding that output into the verify step is
  what's missing.

## Not planned

- **Building your app.** The build is legitimately per-product. Tremvok picks up at "the
  artifact exists".
- **Reconciling GitOps.** Where a service is deployed by a cluster-side reconciler,
  Tremvok's job is to report and verify, not to apply.
