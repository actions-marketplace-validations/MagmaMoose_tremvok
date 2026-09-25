"""A wrangler.toml binding is only real if `wrangler deploy --dry-run` prints it.

ADR-0005 names this as one of four traps that have already cost time, and the reason is that
the config format does not fail loudly on a near-miss: the rate-limit block takes `name` where
every other binding takes `binding`, and an older wrangler pin turns that mistake into a
warning nobody reads. A binding that is quietly absent is a Worker that deploys cleanly and
throws `Cannot read properties of undefined` on its first request.

So the assertion is not "the TOML parses" or "the key is spelled right" — it is that the
binding appears in the bindings table Wrangler itself prints. Anything weaker is checking our
own understanding of the format rather than Wrangler's.

Wrangler is fetched through npx at the version `action.yml` pins, so this exercises the same
tool a deploy would use rather than whatever is on PATH. It skips rather than fails when Node
is unavailable, so a contributor without Node still gets a green local run; CI has Node.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess  # nosec B404
import tomllib

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKERS = ROOT / "workers"

# `npx wrangler@x` downloads on first use; give it room on a cold cache.
DRY_RUN_TIMEOUT = 600


def pinned_wrangler_version() -> str:
    """The version a deploy would run, read from the action rather than restated here."""
    action = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))
    return str(action["inputs"]["cloudflare-wrangler-version"]["default"])


def declared_bindings(config: pathlib.Path) -> set[str]:
    """Every binding name the config declares, by the key each block type actually uses."""
    data = tomllib.loads(config.read_text(encoding="utf-8"))
    names: set[str] = set()

    # Blocks that key their binding as `binding`.
    for key in (
        "services",
        "kv_namespaces",
        "r2_buckets",
        "d1_databases",
        "queues",
        "durable_objects",
        "vectorize",
        "hyperdrive",
        "analytics_engine_datasets",
    ):
        for block in data.get(key, []) or []:
            if isinstance(block, dict) and block.get("binding"):
                names.add(block["binding"])

    # `[assets]` is a single table, not a list, and its binding is optional — a Worker with
    # no `main` does not need one.
    assets = data.get("assets")
    if isinstance(assets, dict) and assets.get("binding"):
        names.add(assets["binding"])

    # `[[unsafe.bindings]]` and `[[ratelimits]]` key their name as `name`, NOT `binding`.
    # That asymmetry is the trap itself, so it is spelled out rather than normalised away.
    for block in data.get("ratelimits", []) or []:
        if isinstance(block, dict) and block.get("name"):
            names.add(block["name"])

    # `[vars]` are not bindings in Cloudflare's vocabulary, but the dry-run prints them in the
    # same table, and a var the Worker reads that Wrangler does not print is just as absent.
    # The router's PRIVATE_SITES is the one that matters: missing, a bound private site's
    # summary is published on the public root.
    names.update((data.get("vars") or {}).keys())

    return names


def worker_dirs() -> list[pathlib.Path]:
    """Every Wrangler config in the repository, templates and this repo's own alike.

    The root `wrangler.toml` is Tremvok's own docs site — the one that actually ships — so
    leaving it out would verify the templates and not the deployment.
    """
    configs = sorted(WORKERS.glob("*/wrangler.toml")) if WORKERS.is_dir() else []
    dirs = [p.parent for p in configs]
    if (ROOT / "wrangler.toml").is_file():
        dirs.append(ROOT)
    return dirs


def stage_name(directory: pathlib.Path) -> str:
    return "repo-root" if directory == ROOT else directory.name


def stage(directory: pathlib.Path, target: pathlib.Path) -> None:
    """Copy just enough for a dry-run: the config, and whatever its `main` points at."""
    if directory != ROOT:
        shutil.copytree(directory, target)
        return
    # The root config's `main` is repo-relative (workers/docs-site/src/…), so the tree it
    # names comes along. Copying the whole repository would work and would be wasteful.
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "wrangler.toml", target / "wrangler.toml")
    main = tomllib.loads((ROOT / "wrangler.toml").read_text(encoding="utf-8")).get("main")
    if main:
        destination = target / main
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / main, destination)


def run_dry_run(directory: pathlib.Path) -> str:
    version = pinned_wrangler_version()
    result = subprocess.run(  # nosec B603 B607
        ["npx", "--yes", f"wrangler@{version}", "deploy", "--dry-run"],
        cwd=directory,
        capture_output=True,
        text=True,
        check=False,
        timeout=DRY_RUN_TIMEOUT,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, f"wrangler deploy --dry-run failed in {directory}:\n{output}"
    return output


@pytest.fixture(scope="module")
def stageable(tmp_path_factory) -> pathlib.Path:
    """A scratch copy of workers/, so a dry-run needing an assets directory can have one."""
    staged = tmp_path_factory.mktemp("workers")
    for directory in worker_dirs():
        target = staged / stage_name(directory)
        stage(directory, target)
        # `[assets].directory` points at the MkDocs build output, which is not in the repo.
        # An empty directory is refused by Wrangler, so one placeholder file stands in.
        data = tomllib.loads((target / "wrangler.toml").read_text(encoding="utf-8"))
        assets_dir = (data.get("assets") or {}).get("directory")
        if assets_dir:
            placeholder = target / assets_dir
            placeholder.mkdir(parents=True, exist_ok=True)
            (placeholder / "index.html").write_text("<html></html>", encoding="utf-8")
    return staged


def _skip_unless_required(reason: str) -> None:
    """Skip locally, FAIL in CI.

    A check that silently skips itself is the failure mode `.claude/COMMON_MISTAKES.md`
    records as "a required check that never reports": the job is green, the binding was never
    verified, and nothing says so. `TREMVOK_REQUIRE_WRANGLER=1` in CI turns every skip here
    into an error, so the only way to a green run is actually running the dry-run.
    """
    if os.environ.get("TREMVOK_REQUIRE_WRANGLER") == "1":
        pytest.fail(f"TREMVOK_REQUIRE_WRANGLER=1 but the dry-run could not run: {reason}")
    pytest.skip(reason)


@pytest.mark.parametrize("name", [stage_name(d) for d in worker_dirs()])
def test_every_declared_binding_appears_in_the_dry_run(name: str, stageable: pathlib.Path) -> None:
    if os.environ.get("TREMVOK_SKIP_WRANGLER") == "1":
        _skip_unless_required("TREMVOK_SKIP_WRANGLER=1")
    if shutil.which("npx") is None:
        _skip_unless_required("Node is not available")

    directory = stageable / name
    declared = declared_bindings(directory / "wrangler.toml")
    assert declared, f"{name}/wrangler.toml declares no bindings at all"

    output = run_dry_run(directory)
    missing = [b for b in sorted(declared) if f"env.{b}" not in output]
    assert not missing, (
        f"{name}: declared but absent from `wrangler deploy --dry-run`: {missing}\n"
        f"A binding Wrangler does not print does not exist.\n{output}"
    )


# Imports the bundle Wrangler built, asks it for /webmcp.js, and runs the answer in a context
# holding only what a page would give it, with a model context that records registrations.
BUNDLED_SCRIPT_CHECK = r"""
import vm from "node:vm";
import { pathToFileURL } from "node:url";
const worker = (await import(pathToFileURL(process.argv[1]).href)).default;
const response = await worker.fetch(new Request("https://docs.magmamoose.com/webmcp.js"), {});
const tools = [];
const page = {
  URL,
  AbortController,
  location: {
    href: "https://docs.magmamoose.com/",
    origin: "https://docs.magmamoose.com",
    assign() {},
  },
  document: { querySelectorAll: () => [] },
  navigator: {
    modelContext: {
      registerTool: (tool) => {
        tools.push(tool.name);
        return Promise.resolve();
      },
    },
  },
  fetch: async () => new Response("", { status: 404 }),
  addEventListener() {},
};
page.window = page;
vm.createContext(page);
vm.runInContext(await response.text(), page);
process.stdout.write(JSON.stringify({ status: response.status, tools }));
"""


def test_the_bundled_router_serves_a_landing_script_that_runs_in_a_page(tmp_path) -> None:
    """The landing page's WebMCP script, as the DEPLOYED router serves it.

    The router's own suite runs the script from source, and source is not what ships: Wrangler
    bundles with esbuild's `keepNames`, which wraps every named function in a `__name(...)`
    helper that exists in the bundle and not in a browser page. A script produced by
    `fn.toString()` passed every Node test and threw a ReferenceError from the bundle before it
    registered a single tool. workers/docs-router/src/webmcp.js keeps the script a string for
    that reason, and this is the test that fails if it stops being one.
    """
    if os.environ.get("TREMVOK_SKIP_WRANGLER") == "1":
        _skip_unless_required("TREMVOK_SKIP_WRANGLER=1")
    if shutil.which("npx") is None or shutil.which("node") is None:
        _skip_unless_required("Node is not available")

    router = tmp_path / "docs-router"
    shutil.copytree(WORKERS / "docs-router", router)
    bundle = tmp_path / "bundle"
    wrangler = f"wrangler@{pinned_wrangler_version()}"
    result = subprocess.run(  # nosec B603 B607
        ["npx", "--yes", wrangler, "deploy", "--dry-run", "--outdir", str(bundle)],
        cwd=router,
        capture_output=True,
        text=True,
        check=False,
        timeout=DRY_RUN_TIMEOUT,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    checked = subprocess.run(  # nosec B603 B607
        ["node", "--input-type=module", "-e", BUNDLED_SCRIPT_CHECK, str(bundle / "index.js")],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    assert checked.returncode == 0, checked.stdout + checked.stderr
    report = json.loads(checked.stdout)
    assert report["status"] == 200
    assert report["tools"] == ["list_docs_sites", "search_docs", "read_page", "open_site"]


def test_the_router_binds_a_service_for_every_site_it_routes() -> None:
    """The router derives its route table from `env`, so wrangler.toml is the only list.

    This asserts the shape that makes that safe: every binding is a service binding, never an
    HTTP fetch to a public origin. ADR-0005 turns on that distinction — proxying an
    Access-gated origin moves the gate off the user and onto the router.
    """
    config = WORKERS / "docs-router" / "wrangler.toml"
    data = tomllib.loads(config.read_text(encoding="utf-8"))
    services = data.get("services") or []
    assert services, "the router routes nothing"
    for block in services:
        assert block["binding"] == block["binding"].upper(), block
        # `docs-<repo>`, matching workers/docs-site/wrangler.toml's naming.
        assert block["service"].startswith("docs-"), block
        expected = block["service"][len("docs-") :].upper().replace("-", "_")
        assert block["binding"] == expected, (
            f"binding {block['binding']} does not map back to service {block['service']}; "
            "the router upper-snakes the path segment to find its binding, so a mismatch "
            "is a 404 that looks like a broken deploy"
        )


def test_no_docs_worker_exposes_a_public_origin() -> None:
    """`workers_dev = false` is the invariant the service-binding design rests on.

    If a site Worker were reachable directly, Access on the router's hostname would be a gate
    with a door beside it.
    """
    for directory in worker_dirs():
        data = tomllib.loads((directory / "wrangler.toml").read_text(encoding="utf-8"))
        assert data.get("workers_dev") is False, (
            f"{stage_name(directory)}/wrangler.toml must set `workers_dev = false`"
        )
