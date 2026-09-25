"""Generate docs/action-reference.md from action.yml.

The reference is a build product, not a hand-maintained page: chargate's README and its
generated reference had already drifted about a default before anyone noticed. Run with
``--check`` in CI to fail when the committed file no longer matches the source.

Which target each input belongs to comes from the same place the runtime validator reads
it — ``gen_input_targets.targets_for``, parsed out of the descriptions in action.yml. A
reference that disagreed with the validator would be worse than no reference: it would
document an input as applicable and then the run would refuse it.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_input_targets import TARGETS, targets_for

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / "action.yml"
OUT = ROOT / "docs" / "action-reference.md"

# One line per target, keyed by the SAME list the validator uses. Derived rather than
# written out, because a hardcoded table drifts: the `docs` row outlived that target's rename
# by a whole branch, and `--check` reported the page as up to date the entire time.
TARGET_SUMMARY = {
    "github-pages": "Build an MkDocs site strictly and publish it to GitHub Pages",
    "cloudflare-docs": "Build an MkDocs site strictly and publish it to Workers Static Assets",
    "s3-cloudfront": "Sync a built static site to S3, invalidate CloudFront",
    "lambda-zip": "Publish a Lambda package to S3, update the function, move an alias",
    "terragrunt": "Discover, plan and (on an approval) apply Terragrunt stacks",
    "ansible": "Run a playbook over SSH, then prove it is idempotent",
    "cloudflare-workers": "Deploy a Worker and its static assets with Wrangler",
    "azure-functions-zip": "Publish a zip to an Azure Function App, then wait for it to answer",
    "azure-apim-policy": "Publish policy documents to an API Management API, all or nothing",
}

_missing = set(TARGETS) - set(TARGET_SUMMARY)
if _missing:  # pragma: no cover - a new target must not reach the page undescribed
    raise SystemExit(f"gen_action_reference: no summary for target(s): {sorted(_missing)}")


# What a caller's job has to grant, per target. A composite action cannot declare
# `permissions:`, so this is the caller's half of the contract and belongs in the reference
# rather than in prose somebody has to find.
PERMISSIONS = {
    "github-pages": [
        ("contents: read", "checkout"),
        ("pages: write", "actions/deploy-pages, in the caller's own job"),
        ("id-token: write", "actions/deploy-pages"),
    ],
    "s3-cloudfront": [
        ("contents: read", "checkout"),
        ("id-token: write", "assume the deploy role by OIDC"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
    "lambda-zip": [
        ("contents: read", "checkout"),
        ("id-token: write", "assume the deploy role by OIDC"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
    "terragrunt": [
        ("contents: read", "checkout"),
        ("id-token: write", "assume the deploy role by OIDC"),
        ("pull-requests: write", "the rolling plan comment"),
        ("checks: write", "the check run that makes apply-before-merge enforceable"),
    ],
    "ansible": [
        ("contents: read", "checkout"),
        ("pull-requests: write", "the sticky run comment"),
    ],
    "cloudflare-workers": [
        ("contents: read", "checkout"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
    "cloudflare-docs": [
        ("contents: read", "checkout"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
    "azure-functions-zip": [
        ("contents: read", "checkout"),
        ("id-token: write", "sign in to Azure by OIDC"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
    "azure-apim-policy": [
        ("contents: read", "checkout"),
        ("id-token: write", "sign in to Azure by OIDC"),
        ("pull-requests: write", "the sticky preview comment"),
    ],
}


def cell(text: str | None) -> str:
    """Collapse whitespace and escape what would otherwise break the table.

    A `|` inside a cell starts a new column. Descriptions here legitimately contain
    them — ``auto | uv | pip`` is how the choices read — and unescaped they made
    markdownlint report "Too many cells, extra data will be missing", which is exactly
    what rendered: the tail of every such description was dropped from the page.
    """
    collapsed = re.sub(r"\s+", " ", (text or "").strip()).replace("|", r"\|")

    # Everything below is one lesson learned three times: an action description is prose
    # written for `--help`, and dropping it into a markdown table renders it as markup.
    # Each of these silently DELETED content from the published page rather than looking
    # wrong, which is why they are escaped here rather than fixed per description:
    #
    #   `|`        starts a new column, truncating the row
    #   `<repo>`   parses as an HTML tag and vanishes
    #   `* a`      parses as emphasis, eating the asterisks
    #
    # Escaping happens only OUTSIDE code spans: inside backticks these are already
    # literal, and an escape there renders as the escape.
    parts = collapsed.split("`")
    for i in range(0, len(parts), 2):  # even indexes are outside code spans
        chunk = parts[i].replace("<", "&lt;").replace(">", "&gt;")
        chunk = re.sub(r"([*_])", r"\\\1", chunk)
        # A bare URL is valid markdown but escapes the theme's link styling, so give it
        # a code span rather than leaving markdownlint to complain about every one.
        chunk = re.sub(r"(?<!\]\()(?<!`)(https?://[^\s)\]]+)", r"`\1`", chunk)
        parts[i] = chunk
    collapsed = "`".join(parts)

    # An empty cell renders as `|  |`, which markdownlint flags as bad column style and
    # which reads as a missing value rather than a deliberate one.
    return collapsed or "—"


def default(value: object) -> str:
    return f"`{value}`" if value not in ("", None) else "not set"


def applies_to(name: str, spec: dict) -> str:
    if name == "target":
        return "the selector"
    targets = targets_for(spec.get("description", ""))
    return "all" if len(targets) == len(TARGETS) else ", ".join(f"`{x}`" for x in targets)


def render() -> str:
    action = yaml.safe_load(ACTION.read_text(encoding="utf-8"))
    inputs = action["inputs"]

    lines = [
        "# Action reference",
        "",
        "<!-- sources: action.yml -->",
        "",
        "Generated by `scripts/gen_action_reference.py`. Edit `action.yml`, not this page.",
        "For the task-shaped version, see [Setup](setup.md).",
        "",
        "## Targets",
        "",
        "`target` is the only required input and it has no default. Everything else is",
        "optional, and every one of them is checked against the target you picked: an input",
        "that belongs to another target is a hard error naming both, before the checkout.",
        "",
        "| Target | What it does |",
        "| --- | --- |",
        *(f"| `{name}` | {TARGET_SUMMARY[name]} |" for name in TARGETS),
        "",
        "## Inputs",
        "",
        f"`MagmaMoose/tremvok@v2` takes {len(inputs)} inputs. `target` is the only one that",
        "is required.",
        "",
        "| Input | Applies to | Default | Description |",
        "| --- | --- | --- | --- |",
    ]
    for key, spec in inputs.items():
        lines.append(
            f"| `{key}` | {applies_to(key, spec)} | {default(spec.get('default'))} "
            f"| {cell(spec.get('description'))} |"
        )

    lines += ["", "## Outputs", "", "| Output | Description |", "| --- | --- |"]
    for key, spec in action["outputs"].items():
        lines.append(f"| `{key}` | {cell(spec.get('description'))} |")

    lines += [
        "",
        "## Required permissions",
        "",
        "Declared by the **caller**, because a composite action cannot declare",
        "`permissions:`. Only what the target actually uses:",
        "",
    ]
    for target, grants in PERMISSIONS.items():
        lines += [
            f"### `target: {target}`",
            "",
            "```yaml",
            "permissions:",
        ]
        lines += [f"  {grant:<22}# {why}" for grant, why in grants]
        lines += ["```", ""]

    lines += [
        "`target: github-pages` is the one target the action cannot finish on its own:",
        "`actions/deploy-pages` needs `pages: write` and the `github-pages` environment, and a",
        "composite action can declare neither. The action builds and stages the artifact; the",
        "caller's job runs `actions/deploy-pages`. Every other target completes inside the",
        "action.",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="fail if the committed file is stale")
    args = ap.parse_args(argv)

    generated = render()
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.is_file() else ""
        if current != generated:
            print(f"{OUT.relative_to(ROOT)} is stale. Run: python scripts/gen_action_reference.py")
            return 1
        print("action-reference.md is up to date")
        return 0
    OUT.write_text(generated, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
