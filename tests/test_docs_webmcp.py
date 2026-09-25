"""The WebMCP script every docs site is given (scripts/docs_webmcp.js), through its own suite.

The script ships into other people's sites and runs in their readers' browsers, where a
mistake fails quietly: a tool that never registers is indistinguishable from a browser without
WebMCP. So tests/js/docs_webmcp.test.mjs runs the file's own bytes in a context holding only
what a page gives a script, and this runs that suite the way pytest runs everything else. It
skips locally without Node and fails under `TREMVOK_REQUIRE_NODE=1`, which CI sets.
"""

from __future__ import annotations

import pathlib
import subprocess  # nosec B404

from tests.nodejs import node

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUITE = ROOT / "tests" / "js" / "docs_webmcp.test.mjs"


def test_the_webmcp_script_suite_passes() -> None:
    result = subprocess.run(  # nosec B603
        [node(), "--test", str(SUITE)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=300,
    )
    assert result.returncode == 0, result.stdout + result.stderr
