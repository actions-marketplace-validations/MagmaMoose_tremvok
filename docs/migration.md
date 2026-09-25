# Migrating to v2

<!-- sources: action.yml -->

v1 is the docs-only action. v2 is one action covering six targets, so the input surface had
to grow a selector and the docs inputs had to move out of the way of it.

**`@v1` is frozen at v1.0.18 and keeps working.** It is not deprecated by this. Migrate
when you want another target, or when you want the input validation.

That sentence used to read "`@v1` keeps working exactly as it does today", and for a day
it was false. The release job moves the floating major tag onto every stable release, and
GitVersion cut both breaking changes as patches, so `v1` was force-moved onto v1.0.19 and
then v1.0.23: every consumer pinned to `@v1` received the v2 contract without asking for
it, and nine repositories went red on `unknown target 'none'`. `v1` now points at
v1.0.18, the last release that actually speaks the v1 contract, and `GitVersion.yml`
makes a breaking change bump the major so the tag can never wander again.

## What changed, and why

`target` at v1 meant *where the built site goes*. At v2 it means *what to deploy*, which is
the collision that forced a major:

```yaml
# v1
- uses: MagmaMoose/tremvok@v1
  with:
    target: github-pages
    toolchain: uv
    strict: true

# v2
- uses: MagmaMoose/tremvok@v2
  with:
    target: github-pages
    pages-toolchain: uv
    pages-strict: true
```

The docs target is now named for the one place it publishes, so `target` says both things at
once and there is no second destination input under it. Every other docs input gained a
`pages-` prefix: with six targets in one action, a bare `toolchain` or `strict` cannot say
whose it is. The prefix is also what the validator keys on, so a misplaced input is caught
rather than ignored.

## Renames

| v1 | v2 |
| --- | --- |
| `target: github-pages` | `target: github-pages`, and it now selects the deploy target itself |
| `toolchain` | `pages-toolchain` |
| `docs-group` | `pages-dependency-group` |
| `requirements` | `pages-requirements` |
| `python-version` | `pages-python-version` |
| `strict` | `pages-strict` |
| `site-dir` | `pages-site-dir` |
| `lint` | `pages-lint` |
| `profile` | `pages-profile` |
| `readme-budget` | `pages-readme-budget` |
| `markdownlint` | `pages-markdownlint` |
| `target: cloudflare-pages` | **removed**: publish a built site with `target: cloudflare-workers` |
| `cloudflare-project`, `cloudflare-account-id`, `cloudflare-api-token`, `cloudflare-branch` | **removed** with it. The Workers target takes `cloudflare-api-token` and `cloudflare-account-id` of its own, and reads the rest from your Wrangler config |
| `require-access` | **removed** with it |
| `stage-pages` | **removed**: it was already a deprecated alias, and staging is no longer a choice |

There is no `docs-target` at v2, and nothing replaces it. GitHub Pages is one site with no
preview destination, so a pull request (`mode: preview`) and a dry run build without staging
an artifact, and a push to the default branch stages one. The mode decides, which is what the
mode means for every other target too.

If you tracked a `docs-*` prefixed pre-release of v2 rather than `@v1`, the rename is
mechanical: `docs-` becomes `pages-`, `target: docs` becomes `target: github-pages`, and
`docs-target` comes out. An input that no longer exists is a hard error naming the target, so
a missed one fails the run before the checkout rather than being ignored.

`working-directory` and `checkout` are unchanged: they genuinely apply to every target.

## Outputs

| v1 | v2 |
| --- | --- |
| `toolchain` | `pages-toolchain` |
| `target` | `target`, now the selector you passed in, not the docs destination |
| `site-dir` | unchanged |
| `page-url`, `deployment-url` | **removed**: the Pages URL comes from your own `deploy-pages` step, and any other target's published URL is `url` |

## The reusable workflows are gone

`.github/workflows/docs.yml` and `docs-github-pages.yml` were the v1 quickstart. They are
removed at v2: one action is the whole product, and a second callable surface for one target
only was a place for the two to disagree.

The half they carried that the action cannot is the Pages deploy: `actions/deploy-pages`
needs `pages: write` and the `github-pages` environment, and a composite action can declare
neither. That becomes a job in your own workflow, the shape is in [Setup](setup.md), and it
is about ten lines. It is the only place in the action where an `environment:` is
load-bearing; the Terragrunt apply gate is the action's own logic and needs none.

Callers who used `docs.yml` for Cloudflare Pages need a different target: `cloudflare-workers`
publishes a built directory with Wrangler, needs no GitHub permission, and completes inside the
action. [Setup](setup.md#cloudflare-workers) has the job.

## The subdirectory entrypoint is gone

`MagmaMoose/tremvok/deploy@v1` no longer exists. Its three targets are `target:
s3-cloudfront`, `target: lambda-zip` and `target: terragrunt` on the root action, with these
renames:

| `deploy/` | v2 |
| --- | --- |
| `role-to-assume` | `aws-role-to-assume` |
| `role-duration-seconds` | `aws-role-duration-seconds` |
| `bucket` | `s3-bucket` |
| `key-prefix` | `s3-key-prefix` |
| `delete-orphans` | `s3-delete-orphans` |
| `distribution-id` | `cloudfront-distribution-id` |
| `site-url` | `cloudfront-site-url` |
| `function-name` | `lambda-function-name` |
| `function-alias` | `lambda-function-alias` |
| `version-label` | `lambda-version-label` |
| `terraform-root` | `terragrunt-root` |
| `check-name` | `terragrunt-check-name` |

It never appeared in a release note, and the three files in `examples/` that pointed at it
were pointing at the root action anyway, which is a large part of why the surfaces merged.

## Behaviour changes worth knowing

- **A wrong input now fails the run.** At v1 an input the action did not declare produced a
  warning and was ignored. At v2 an input belonging to another target is an error naming
  both, raised before the checkout.
- **The Terragrunt apply uses the saved plan.** Plan writes `-out`, apply applies that file.
  When the saved plan has gone stale the run says so in the log and re-plans rather than
  refusing, `PLAN SOURCE:` in the log names which one ran.
- **A plan-only Terragrunt run reports success, not failure.** It deployed nothing on
  purpose. At v1 the notification called that a failed deploy.
- **`schedule` and `pull_request_review` resolve.** `mode: auto` used to fail on both, which
  broke the Terragrunt drift run on its own cron.
