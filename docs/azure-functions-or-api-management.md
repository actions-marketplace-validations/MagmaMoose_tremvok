# Azure: a Function or API Management?

Both Azure targets give a repository an HTTP endpoint it deploys into:
[`azure-functions-zip`](setup.md#azure-functions-zip) publishes code to a Function App,
[`azure-apim-policy`](setup.md#azure-apim-policy) publishes policies to an API Management API.
They suit different jobs, and the job decides.

## API Management, when the endpoint is glue

The endpoint receives a request, checks it, reshapes it and hands it on: to a Storage queue, a
Service Bus topic, another API. A webhook receiver that verifies a signature and queues a
pointer is the typical case.

- **There is no code to host.** The logic is a policy: XML with C# expressions, compiled by the
  gateway. No runtime version to pin, no package to build, no worker to start, and nothing to
  migrate when a hosting plan is retired.
- **Azure services by managed identity, in one element.** `authentication-managed-identity`
  inside `send-request` calls Storage, Service Bus or Event Hubs with the instance's own
  identity. For a Storage queue it is the Put Message call the SDK makes, with the same message
  time-to-live (`messagettl`) and the same role, `Storage Queue Data Message Sender`, scoped to
  the one queue. Answer the caller only after the queue has returned `201`, and a failed enqueue
  is still a failed delivery the sender can see. Wrap the call in `retry` if you want the SDK's
  retries.
- **Cheap at low volume.** The Consumption tier includes a million calls a month.
- **Checked on publish.** API Management refuses a policy whose XML or expressions do not
  compile, and `azure-apim-policy` puts the previous set back when it does.

## A Function, when the endpoint is a program

- It needs a library, an SDK or more logic than reads comfortably as policy expressions. A few
  dozen lines of C# in attributes is the practical ceiling.
- It needs unit tests. A policy expression can only be exercised against a live gateway.
- It consumes rather than answers: queue, timer, blob or Event Grid triggers. API Management
  only answers requests; it cannot drain a queue or run on a schedule.
- It works for longer than a caller should wait, or keeps state between calls.

Linux Consumption retires on 30 September 2028. Create a new Function App on Flex Consumption.

## What they share

- **The same sign-in.** `azure-client-id`, `azure-tenant-id` and `azure-subscription-id`, and
  one federated credential per repository.
- **Cold starts** on their consumption tiers. A caller with a hard deadline (a chat platform's
  outgoing webhook may allow five seconds, a git host ten) should get its answer from a short
  path, with the slow work after a queue.
- **No preview destination** on the consumption tiers. A pull request publishes nothing unless
  the Function App has a slot.

## In one line each

| The endpoint | Target |
|---|---|
| verifies, reshapes, and queues or forwards | `azure-apim-policy` |
| needs a package, a library or tests | `azure-functions-zip` |
| is triggered by a queue, a timer or a blob | `azure-functions-zip` |
| must answer within seconds but do slow work | `azure-apim-policy` in front, a queue, a worker behind it |

## Who owns the policy

If the team that runs the infrastructure owns the policy, and it changes with the
infrastructure, keep it in the infrastructure code (Terraform's `xml_content`, a Bicep
`policies` resource) and this target is not needed. Use `azure-apim-policy` when an application
repository owns the endpoint's behaviour and ships it on its own cadence, the way function code
is shipped. Give each policy one owner: two writers overwrite each other on every run.
