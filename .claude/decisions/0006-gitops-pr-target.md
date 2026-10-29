# 6. A GitOps deploy is a pull request, and it is Tremvok's

**Status:** accepted · **Date:** 2026-10-01

## Context

Services a cluster-side reconciler deploys (Flux, Argo CD) change environment when a commit
changes the overlay the reconciler reads. The common way to make that commit is image
automation: Flux's `ImageUpdateAutomation` watches the registry and pushes the newest matching
tag straight to the branch the cluster reads. For acceptance and production that makes every
release a deployment nobody reviewed, and "what runs in prd" whatever the last automation commit
said.

The first version of this was built into Diatreme (v2.18.0, `deploy-pr-targets` and
`mode: deploy-promote`), because Diatreme already holds the version and the images at the moment
of release. That is the wrong boundary: Diatreme answers "what version, and is it released?",
and changing what an environment runs is the deploy side's question. It moved here before any
repository adopted it.

The docs said Tremvok does not reconcile GitOps. It still does not: the reconciler applies.
What this target does is propose the change to Git, which is the deploy step a GitOps service
has.

## Decision

Add `target: gitops-pr`.

- `release: published` opens a deploy PR for the first overlay in `gitops-overlays`, moving every
  image in `gitops-images` to the release's tag. Diatreme publishes the GitHub Release after the
  image is in the registry, so the event itself is the hand-off, and no output has to cross a
  workflow boundary.
- A push that merged a deploy PR (found with `resolve-merged-pr.sh`, the same lookup the
  terragrunt apply-on-merge uses) opens exactly what the merge changed in that overlay for the
  next one. What travels is read from the merged file, not from the pull request's metadata.
- One open deploy PR per overlay, on a branch per tag (`deploy/<overlay>/<tag>`). An open pull
  request's branch is never reset: GitHub marks a pull request merged the moment its head points
  at a commit the base contains.
- Only the value on the `newTag:` line changes. yq locates it, sed rewrites it, yq reads it back.
- Commits go through the contents API with the caller's App token: signed, and the pull requests
  it opens run their workflows, which pull requests opened with GITHUB_TOKEN do not.

## Consequences

- The release side keeps two guards of its own, in Diatreme: refusing to release a push that
  only changed the overlays (the merge of a deploy PR), and skipping the image build on a pull
  request that only moves tags.
- A pull request run deploys nothing, and there is no rollback mode: reverting a deploy is
  reverting its merge, which is reviewed like the deploy was. With `gitops-preview-labels` a
  pull request run settles preview label claims, which deploys nothing either: see
  [0007](0007-gitops-preview-claims.md).
- "Did it take effect?" is answered in two halves. The target reads the deploy branch back and
  checks every tag. What the cluster did is `verify-url`'s, on the run the merge starts; waiting
  for the reconciler's own commit status would be stronger and needs the reconciler to report
  one.
- Overlays live in the repository that releases. A separate GitOps repository would need a token
  scoped to it and is not supported yet.
