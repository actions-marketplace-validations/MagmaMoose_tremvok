# Ready-to-copy workflows

One file per target. Copy the one you need to `.github/workflows/`, set the repository
variables it reads, and you are done: the logic lives in the versioned action, so a fix
reaches you through `@v2` rather than through nine copy-paste edits.

| File | Target | For |
|---|---|---|
| [`github-pages.yml`](github-pages.yml) | `github-pages` | an MkDocs site on GitHub Pages |
| [`cloudflare-docs.yml`](cloudflare-docs.yml) | `cloudflare-docs` | an MkDocs site on Workers Static Assets, behind the docs router |
| [`deploy-s3-cloudfront.yml`](deploy-s3-cloudfront.yml) | `s3-cloudfront` | a built static site on S3 + CloudFront |
| [`deploy-lambda.yml`](deploy-lambda.yml) | `lambda-zip` | a Lambda package |
| [`terragrunt.yml`](terragrunt.yml) | `terragrunt` | Terraform/Terragrunt stacks, the Atlantis replacement |
| [`ansible.yml`](ansible.yml) | `ansible` | a fleet configured over SSH |
| [`cloudflare-workers.yml`](cloudflare-workers.yml) | `cloudflare-workers` | a Worker and its static assets, published with Wrangler |
| [`azure-functions.yml`](azure-functions.yml) | `azure-functions-zip` | a .NET function on an Azure Function App |
| [`azure-apim-policy.yml`](azure-apim-policy.yml) | `azure-apim-policy` | policies on an existing Azure API Management API |

They differ only in `target:` and that target's inputs. Everything shared (`mode`,
`verify-url`, the notification sinks) is spelled the same way in all seven, which is the
point of one action rather than seven.

Four conventions they inherit, so they leave the per-repo file:

- `runs-on: ${{ vars.SELFHOSTED_GITHUB_RUNNER || 'ubuntu-latest' }}`, because GitHub-hosted
  minutes are metered on private repositories.
- **Never cancel a production deploy; do cancel a superseded preview.** That is what the
  `cancel-in-progress` expression says.
- `permissions: id-token: write` on the AWS targets and on the two Azure targets, because
  the whole point is that no repository stores a cloud key — and for Azure, no publish
  profile either. `cloudflare-workers` needs none: it authenticates with an API token, and
  touches no AWS or Azure account.
- A fork pull request never reaches a credential. The action skips one with a reason; the
  `if:` on the job is the belt for the targets where that matters most.

`github-pages.yml` is the only one with a second job, and only because `actions/deploy-pages`
requires `pages: write` and the `github-pages` environment, which a composite action cannot
declare. Every other target completes inside the action.

`cloudflare-docs.yml` publishes the same MkDocs build as `github-pages.yml` but needs no
second job, because Wrangler requires neither `pages: write` nor an environment. It publishes
nothing on a pull request for a third reason again: its Workers set `workers_dev = false` and
carry no route, so there is no address a preview could be served from.

`azure-functions.yml` is the one whose pull-request path publishes nothing at all: a Linux
Consumption plan has no deployment slots, so there is no preview destination that does not
take production traffic, and the run validates the package and says so rather than shipping a
branch to production. On Premium or Dedicated, `functions-slot` gives it one.

Two of them have no destination input at all, for opposite reasons. `github-pages` has one
site and no preview destination, so a pull request builds without staging an artifact and
the mode is the whole decision. `cloudflare-workers` reads the asset directory, routes,
custom domain and 404 handling from your `wrangler.toml`, so what ships is what was reviewed
in the repository.
