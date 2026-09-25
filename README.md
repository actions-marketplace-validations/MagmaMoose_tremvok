# Tremvok

[![CI](https://github.com/MagmaMoose/tremvok/actions/workflows/ci.yaml/badge.svg)](https://github.com/MagmaMoose/tremvok/actions/workflows/ci.yaml)
[![Release](https://img.shields.io/github/v/release/MagmaMoose/tremvok?sort=semver&logo=github)](https://github.com/MagmaMoose/tremvok/releases)
[![Docs](https://img.shields.io/badge/docs-tremvok-brightgreen)](https://magmamoose.github.io/tremvok/)
[![License](https://img.shields.io/github/license/MagmaMoose/tremvok)](LICENSE)

> **Ship it, prove it went live.**

One GitHub Action for the whole deploy side: documentation sites, static sites on
S3/CloudFront, Cloudflare Workers, Azure Functions, Lambda packages, Terragrunt stacks and
fleets over Ansible. Pick a target, pass that target's inputs, and Tremvok deploys it,
verifies it actually serves, and tells the humans. It is the counterpart to
[Diatreme](https://github.com/MagmaMoose/diatreme): Diatreme decides *what version and
whether it is released*, Tremvok gets it *live and confirms it*.

**[Documentation](https://magmamoose.github.io/tremvok/)** ·
[Action reference](https://magmamoose.github.io/tremvok/action-reference/) ·
[Setup](https://magmamoose.github.io/tremvok/setup/)

## Quickstart

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  push: { branches: [main] }
  pull_request:

permissions:
  contents: read
  id-token: write        # assume the deploy role; no key is stored anywhere
  pull-requests: write   # the sticky preview comment

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v4
      - run: npm ci && npm run build

      - uses: MagmaMoose/tremvok@v2
        with:
          target: s3-cloudfront
          artifact-path: dist
          s3-bucket: ${{ vars.SITE_BUCKET }}
          cloudfront-distribution-id: ${{ vars.CLOUDFRONT_DISTRIBUTION }}
          aws-role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}
          aws-region: eu-west-1
          verify-url: https://example.com
```

Swap `target:` and its inputs for another target. Ready-to-copy workflows for each live in
[`examples/`](examples/).

## What it does

- **Nine targets, one action**: `github-pages`, `cloudflare-docs`, `cloudflare-workers`,
  `azure-functions-zip`, `azure-apim-policy`, `s3-cloudfront`, `lambda-zip`, `terragrunt`,
  `ansible`. `target` is the only required input.
- **Every input is checked against the target.** An input belonging to another target is a
  hard error naming both, before the checkout, never a silent no-op. That is what stops a
  target enum from becoming a listing that cannot say what it does.
- **Verifies rather than assumes.** A deploy platform reports success once it *accepts* an
  artifact, which is not the site answering. Tremvok requests the URL, checks the status and
  a response header, and retries. Ansible goes further: a second check-mode run has to find
  nothing left to change, because a zero exit only proves the playbook ran. On Azure the exit
  code actively lies — `az` reports `Bad Request` over deploys that worked, and a Function App
  reports `Running` while serving 503 — so only an answer from the app counts.
- **Applies the plan that was reviewed.** The Terragrunt target plans, saves the plan, gates
  on an independent pull-request approval, then applies that saved plan, and publishes a
  check run you can make required, which turns apply-before-merge into a rule.
- **No stored cloud credential.** OIDC to a role assumed per run, expiring in an hour. The
  same argument that deletes Atlantis.
- **Notifications that never fail a deploy.** Sticky pull-request comment, Slack, Teams,
  each optional and failure-isolated, plus an optional API recording every deployment.

## Most-used inputs

| Input | Applies to | What it does |
| --- | --- | --- |
| `target` | — | `github-pages` · `cloudflare-docs` · `cloudflare-workers` · `azure-functions-zip` · `azure-apim-policy` · `s3-cloudfront` · `lambda-zip` · `terragrunt` · `ansible`. Required. |
| `mode` | all | `auto` (default) reads the event: push = deploy, pull request = preview. |
| `artifact-path` | s3, lambda, cloudflare, functions | The built artifact. A directory, or a `.zip`. |
| `aws-role-to-assume` | the AWS targets | Role assumed with this run's OIDC token. |
| `verify-url` | all | Requested after the deploy; a non-2xx fails the run. |
| `cloudflare-api-token` | cloudflare-workers | Wrangler's credential. Pass a secret. |
| `functions-app-name`, `apim-api-id` | the Azure targets | The Function App, or the API Management API. `azure-client-id` signs in by OIDC. |
| `ansible-playbook` | ansible | Playbook to run. `ansible-inventory` goes with it. |

All 125 inputs, and the permissions each target needs →
**[Action reference](https://magmamoose.github.io/tremvok/action-reference/)**

## The one job Tremvok hands back

A composite action cannot declare `permissions:` or `environment:`, and
`actions/deploy-pages` needs both. So `target: github-pages` builds
and stages the artifact, and a job of yours runs `actions/deploy-pages`. See
[Setup](https://magmamoose.github.io/tremvok/setup/). Every other target completes inside
the action.

## Where it sits

[Diatreme](https://github.com/MagmaMoose/diatreme) releases ·
**Tremvok** deploys and verifies ·
[Chargate](https://github.com/MagmaMoose/chargate) gates security ·
[Brimyr](https://github.com/MagmaMoose/brimyr) gates tests

Accent gemstone: **peridot**.

## Versioning

Pin `@v2` for the floating major, or a tag or SHA to freeze. `@v1` is the docs-only action
and keeps working unchanged; see [Migrating to v2](https://magmamoose.github.io/tremvok/migration/).

## Security · Contributing · License

[Report a vulnerability](https://github.com/MagmaMoose/tremvok/security/advisories/new) ·
[Contributing](https://github.com/MagmaMoose/.github/blob/main/CONTRIBUTING.md) ·
Apache-2.0, see [LICENSE](LICENSE).
