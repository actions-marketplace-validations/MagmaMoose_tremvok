# Quick start (most-run commands)

**Action surface (repo root):**
```bash
shellcheck -S warning scripts/*.sh scripts/lib/*.sh   # lint
bats tests/bats                                        # 314 shell tests
python3 scripts/gen_input_targets.py                   # REGENERATE after any input change
python3 scripts/gen_action_reference.py                # REGENERATE after any input change
uv run pytest tests/test_action_contract.py tests/test_input_targets.py -q
git update-index --chmod=+x scripts/<file>.sh          # mark a new script executable
```

**API surface:**
```bash
uv sync --all-groups
uv run pytest -q            # 181 tests, no network, no AWS
uv run ruff check .         # E,F,I,UP,B,SIM,RUF,S,BLE
uv run ruff format .
uv run mypy src
python3 scripts/build_api_zip.py --arch arm64    # -> dist/tremvok-api.zip + sha256
```

**Infrastructure:**
```bash
make -C terraform validate     # tofu validate the module
make -C terraform dev          # LocalStack: up + build + apply + smoke
make -C terraform serve        # uvicorn against LocalStack, fast inner loop
make -C terraform down         # stop and discard
```

**Docs:**
```bash
uv run --group docs mkdocs serve    # preview at :8000
```

**Docs router (`workers/docs-router/`):**
```bash
node --test workers/docs-router/test/router.test.mjs   # or: uv run pytest tests/test_docs_router.py
node --test tests/js/docs_webmcp.test.mjs             # the WebMCP script every docs site gets
npx wrangler@<cloudflare-wrangler-version> deploy --dry-run   # from workers/docs-router: the bindings table is the check
```
