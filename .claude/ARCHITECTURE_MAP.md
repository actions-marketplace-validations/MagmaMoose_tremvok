# Architecture map

Two surfaces, one repo, no shared imports. They talk over HTTP.

**Action** — `action.yml` is glue: it maps inputs to env vars and runs a script in `scripts/`.
One action, nine targets selected by `target` (the list is in `action.yml`); only the adapter
differs. The pipeline is
validate → resolve → preflight → auth → *adapter* → verify → outcome → notify → record.
`scripts/lib/common.sh` holds logging, `set_output` (heredoc form for multi-line), `is_true`,
`slug`, `retry`; everything sources it.

**API** — `src/tremvok/`: FastAPI + Mangum on Lambda, DynamoDB behind `store.py`, OIDC verified
in `oidc.py` with no crypto dependency. `models.py` is the wire contract.

Per-file purposes for both live in `PROJECT_INDEX.json`. Read it by path; it is not imported.

## The four invariants worth knowing before you edit

**The applicability map is generated, never hand-edited.** `gen_input_targets.py` parses the
`<target>: ` prefix off each input description in `action.yml` into
`scripts/lib/input-targets.json`. `validate-inputs.sh` reads that JSON with jq;
`gen_action_reference.py` reads the same parser. One source, so the runtime check and the
published page cannot disagree. CI fails on drift.

**The API auth dependency must stay module-level.** `api/app.py` uses
`from __future__ import annotations`, so FastAPI resolves annotations against *module* globals.
A `Depends` on a closure inside `create_app` silently degrades to a required query parameter —
the auth check vanishes rather than fails.

**LocalStack runs the same module, not the same code path.** `terraform/localstack/`
instantiates `modules/tremvok-api` with `localstack = true`, which swaps API Gateway for a
Lambda Function URL and skips the alarms. Payload format 2.0 is identical; the path is not.

**The cost ceiling is three independent caps** — API Gateway throttle, Lambda reserved
concurrency, provisioned DynamoDB — because AWS has no spend cap and Budgets only report.
