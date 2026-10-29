# 7. A preview label is a claim, and the first pull request to take it holds it

**Status:** accepted · **Date:** 2026-10-23

## Context

Label-driven preview controllers deploy the open pull request that carries a label to that
label's environment. Flux Operator does it with a `ResourceSetInputProvider` of type
`GitHubPullRequest`, `filter.labels: [deploy/preview-1]` and `filter.limit: 1`. With two open
pull requests carrying the label it takes the newest-created one, GitHub's default list order,
and says nothing: a second pull request takes a single-tenant environment from the first, and
neither author is told.

0006 says a gitops-pr pull request run deploys nothing. Settling the labels keeps that true:
the controller deploys, and the run only takes labels off and comments.

## Options considered

- **Newest claim wins** (what the controller does). Rejected: it is the silent steal.
- **Each run judges only its own pull request.** Two claims at once could both win, and a run a
  concurrency group cancelled would leave its pull request unsettled.
- **Earliest label event wins, every run settles the whole label.** Chosen.

## Decision

`gitops-preview-labels` on `target: gitops-pr`, acting on a pull request run (`mode: preview`)
for `pull_request` `labeled`, `unlabeled` and `closed`.

- The holder is the open pull request whose label went on first, by its latest `labeled` issue
  event, the event id breaking a tie inside one second. Every run reads the same events, so two
  claims made at once end the same way in both runs. A claim with no event to show for it ranks
  last.
- Every run settles the whole label: the holder gets a sticky comment, every other claim gets
  one naming the holder and then loses the label. A refused claim is a green run.
- The comment records the state (`held`, `refused`, `released`), and only a pull request whose
  comment says `held` releases. Taking a label off with an App token fires `unlabeled` again,
  and that run must not tell a refused pull request it released anything. The refusal is
  written before the label comes off for the same reason.
- Closing releases, and takes the preview labels off: a reopened pull request carrying one
  would otherwise take the environment back unannounced.
- Open pull requests are listed through the pulls API, not the issues one, so the token needs
  only `pull-requests: write`, and GITHUB_TOKEN will do.

## Consequences

- Comments are failure-isolated, as every notification is. A label that cannot be taken off
  fails the run, because the controller would still deploy that pull request.
- Consumers run it in its own workflow with a concurrency group per label and `queue: max`;
  without the queue, a third event for a label cancels the run that was waiting, which the
  next run's settling covers, except for a release comment that run would have written.
- A fork pull request is skipped like every fork run; its token cannot write.
- Ranking reads up to ten pages of events per contested pull request and ten pages of open pull
  requests.
