# 5. API Management policies are a deployment target, beside Functions

**Status:** accepted · **Date:** 2026-09-24

## Context

`azure-functions-zip` was added for one kind of endpoint: an internet-facing receiver that
verifies a signed webhook, puts a pointer on a Storage queue and answers, so a worker on a
private network can drain the queue outbound. It works, and it carries a program to host for
what is a few dozen lines of logic: a runtime version to pin (one that starts, measured), a
package whose layout fails silently, a deploy CLI whose exit code lies, and a hosting plan
(Linux Consumption) that retires in 2028.

API Management does the same job in policy. `send-request` with
`authentication-managed-identity` calls the Queue Storage REST API with the instance's identity:
the same Put Message the SDK makes, with the same time-to-live and the same queue-scoped role.
Policy expressions include `HMACSHA256`, so the signature check moves too, and the Consumption
tier is free for a million calls a month. What it cannot do is consume a queue, run on a
schedule, or hold logic that wants tests.

## Decision

Add `target: azure-apim-policy`. It publishes a directory of policy documents, `api.xml` for the
API scope and `<operation-id>.xml` per operation, into an API that already exists, the way
`azure-functions-zip` publishes code into an existing Function App. It creates nothing: an
operation a document names but the API lacks is refused before anything is published.

Publishing is all or nothing. API Management compiles a policy only on PUT and has no dry run,
so the target reads every scope's current policy first and, when a document is refused, puts
back the scopes it already replaced or clears those that had none.

The two targets are documented side by side (`docs/azure-functions-or-api-management.md`):
API Management for glue that verifies, reshapes and queues or forwards; Functions for a program
that needs libraries, tests, triggers or long work.

## Consequences

- A pull request publishes nothing. A policy's only non-production destination is an API
  revision, which is a lifecycle of its own and not this target's to invent.
- `rawxml` is the default format, because that is how policies are written in the portal and in
  Terraform's `xml_content`; `xml` is there for documents written as strict XML.
- Policy expressions cannot be unit-tested off a gateway. `verify-url` is where a caller asserts
  behaviour, and a policy that outgrows that belongs in a Function.
