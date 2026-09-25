"""Node for the suites that are JavaScript: found, version-checked, and never skipped in CI.

The router and the docs sites' WebMCP script are JavaScript and everything else here is pytest,
so each JavaScript suite has a pytest file that runs it, and CI cannot drift from what a
contributor saw. A suite skips locally when Node is missing and FAILS under
`TREMVOK_REQUIRE_NODE=1`, which CI sets: a check that quietly skips itself is the "required
check that never reports" in `.claude/COMMON_MISTAKES.md`.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess  # nosec B404

import pytest

# The suites import ES modules from directories with no package.json, which Node loads by
# syntax detection: unflagged in 22.7 and backported to 20.19. Older, a suite dies on its first
# import with "is a CommonJS module", which reads like a bug in the code under test.
MIN_NODE = (20, 19)


def skip_unless_required(reason: str) -> None:
    if os.environ.get("TREMVOK_REQUIRE_NODE") == "1":
        pytest.fail(f"TREMVOK_REQUIRE_NODE=1 but a Node suite could not run: {reason}")
    pytest.skip(reason)


def node() -> str:
    path = shutil.which("node")
    if path is None:
        skip_unless_required("Node is not available")
    version = subprocess.run(  # nosec B603
        [str(path), "--version"], capture_output=True, text=True, check=False, timeout=30
    ).stdout.strip()
    match = re.match(r"v(\d+)\.(\d+)", version)
    if not match or (int(match.group(1)), int(match.group(2))) < MIN_NODE:
        skip_unless_required(f"Node {version or '?'} is older than {'.'.join(map(str, MIN_NODE))}")
    return str(path)
