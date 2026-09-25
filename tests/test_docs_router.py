"""The docs router on docs.magmamoose.com: its behaviour, and the two contracts it depends on.

The router is JavaScript and everything else here is pytest, so this file is the bridge:
`uv run pytest` runs the router's own node:test suite the way it runs everything else, and
CI cannot drift from what a contributor saw. The suite skips locally when Node is missing
and FAILS under `TREMVOK_REQUIRE_NODE=1`, which CI sets: a check that quietly skips itself
is the "required check that never reports" in `.claude/COMMON_MISTAKES.md`.

The contracts are the ones nothing else would notice breaking:

- The root lists each site by the title and summary in that site's llms.txt, which
  `scripts/gen_docs_index.py` writes. If its layout drifts, the router does not fail: it
  degrades, by design, to listing every site under its bare repository name. Graceful is
  exactly what makes it silent, so the layout is pinned here, across the language boundary.
- The router builds every canonical URL from one origin constant. If the route in
  wrangler.toml moves and the constant does not, every canonical link, sitemap entry and
  llms.txt URL on the root points at a host that no longer serves it.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess  # nosec B404
import tomllib

from scripts.gen_docs_index import render_llms_txt

from tests.nodejs import node

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROUTER = ROOT / "workers" / "docs-router"
SUITE = ROUTER / "test" / "router.test.mjs"
SITES_JS = ROUTER / "src" / "sites.js"
WRANGLER = ROUTER / "wrangler.toml"


def test_the_router_suite_passes() -> None:
    result = subprocess.run(  # nosec B603
        [node(), "--test", str(SUITE)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=300,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def parse_with_the_router(text: str) -> dict[str, str | None]:
    """Run sites.js's own parser over `text`, rather than a Python reading of what it does."""
    script = (
        f"import {{ parseLlmsTxt }} from {json.dumps(SITES_JS.as_uri())};"
        'import { readFileSync } from "node:fs";'
        'process.stdout.write(JSON.stringify(parseLlmsTxt(readFileSync(0, "utf8"))));'
    )
    result = subprocess.run(  # nosec B603
        [node(), "--input-type=module", "-e", script],
        input=text,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_the_root_reads_the_llms_txt_the_build_writes() -> None:
    """What gen_docs_index.py writes is what sites.js parses, curly quotes and all.

    The quotes are the point of the UTF-8 half: the router serves .txt with a charset because
    a client that guesses Latin-1 garbles them, and a parser that mangled them would be the
    same defect one layer in.
    """
    # Escapes rather than the characters, so the source says exactly which ones they are.
    description = (
        "Docs for the \u2018deploy side\u2019: pages, workers and "
        "\u201cverified\u201d releases\u2026"
    )
    text = render_llms_txt(
        site_name="Tremvok",
        site_description=description,
        site_url="https://docs.magmamoose.com/tremvok/",
        entries=[],
    )
    assert parse_with_the_router(text) == {"title": "Tremvok", "summary": description}


def test_a_site_with_no_description_is_still_titled() -> None:
    """`site_description` is optional in mkdocs.yml; the H1 alone must still name the site."""
    text = render_llms_txt(
        site_name="draventis",
        site_description="",
        site_url="https://docs.magmamoose.com/draventis/",
        entries=[],
    )
    assert parse_with_the_router(text) == {"title": "draventis", "summary": None}


def test_the_canonical_origin_is_the_host_the_router_is_routed_on() -> None:
    config = tomllib.loads(WRANGLER.read_text(encoding="utf-8"))
    patterns = [route["pattern"] for route in config["routes"] if route.get("custom_domain")]
    match = re.search(r'export const ORIGIN = "https://([^"/]+)";', SITES_JS.read_text("utf-8"))
    assert match, "sites.js no longer declares ORIGIN the way this test reads it"
    assert patterns == [match.group(1)], (
        f"wrangler.toml routes {patterns} but the router writes canonical URLs for {match.group(1)}"
    )


def test_the_private_sites_are_declared_before_they_are_bound() -> None:
    """PRIVATE_SITES keeps a bound, Access-gated site off the public root.

    A service binding call does not pass through Access, so without it the root would read a
    private site's llms.txt in-process and publish its name and summary. The list is declared
    before any of them is bound, so the day one is, there is no second edit to forget.
    """
    config = tomllib.loads(WRANGLER.read_text(encoding="utf-8"))
    declared = config.get("vars", {}).get("PRIVATE_SITES")
    assert isinstance(declared, list), "PRIVATE_SITES must be a JSON array in [vars]"
    assert declared, "PRIVATE_SITES is empty"
    for name in declared:
        assert re.fullmatch(r"[a-z0-9][a-z0-9-]*", name), f"{name!r} is not a repository name"
