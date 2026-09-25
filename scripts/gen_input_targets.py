"""Generate scripts/lib/input-targets.json from action.yml.

The action has one input surface and five targets. Which inputs apply to which target is
the fact that makes a target enum honest rather than a listing that cannot say what it
does — so it is derived from the input descriptions rather than maintained a second time
next to them.

The convention: an input's description may open with a comma-separated list of target
names followed by a colon. ``s3-cloudfront, lambda-zip: the bucket.`` applies to those two.
Anything else — ``Post-deploy: the URL that must answer.`` — applies to every target,
because ``Post-deploy`` is not a target name.

Run with ``--check`` in CI to fail when the committed file no longer matches action.yml.
The runner never parses YAML: ``validate-inputs.sh`` reads this JSON with jq, which is on
every runner, and PyYAML is not.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / "action.yml"
OUT = ROOT / "scripts" / "lib" / "input-targets.json"

TARGETS = [
    "github-pages",
    "cloudflare-docs",
    "s3-cloudfront",
    "lambda-zip",
    "terragrunt",
    "ansible",
    "cloudflare-workers",
    "azure-functions-zip",
    "azure-apim-policy",
]

# The opening `<targets>:` marker. Bounded to one line so a description whose *body*
# happens to contain a colon cannot be read as a target list.
MARKER = re.compile(r"^([a-z0-9][a-z0-9-]*(?:\s*,\s*[a-z0-9][a-z0-9-]*)*)\s*:\s")


def targets_for(description: str) -> list[str]:
    """The targets an input applies to, from the marker at the head of its description."""
    # `splitlines()` on a description that is only whitespace returns an EMPTY list, so
    # indexing [0] raised IndexError and took the whole generator down with it — and with it
    # CI, since the map and the reference are both --check'd. Nothing in action.yml is
    # whitespace-only today, which is exactly why it went unnoticed. Default the missing
    # first line to "" instead: no marker means every target, which is the right answer.
    lines = (description or "").strip().splitlines()
    first_line = lines[0] if lines else ""
    match = MARKER.match(first_line)
    if not match:
        return list(TARGETS)
    named = [token.strip() for token in match.group(1).split(",")]
    if all(token in TARGETS for token in named):
        return named
    # A prefix that is not a target list is prose. `Post-deploy:` and `docs` differ only
    # by being in TARGETS, which is the whole point of checking rather than assuming.
    return list(TARGETS)


def build() -> dict:
    action = yaml.safe_load(ACTION.read_text(encoding="utf-8"))
    inputs = {}
    for name, spec in action["inputs"].items():
        if name == "target":
            continue  # the selector itself is not selected against
        inputs[name] = {
            "targets": targets_for(spec.get("description", "")),
            "default": str(spec.get("default", "")),
        }
    return {"targets": TARGETS, "inputs": inputs}


def render() -> str:
    return json.dumps(build(), indent=2, sort_keys=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="fail if the committed file is stale")
    args = ap.parse_args(argv)

    generated = render()
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.is_file() else ""
        if current != generated:
            print(f"{OUT.relative_to(ROOT)} is stale. Run: python scripts/gen_input_targets.py")
            return 1
        print("input-targets.json is up to date")
        return 0
    OUT.write_text(generated, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
