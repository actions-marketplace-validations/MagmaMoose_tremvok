"""The contract between `action.yml`, `scripts/` and the README.

`action.yml` is glue: it maps inputs to environment variables and runs a script. Every joint in
that chain can be wrong in a way nothing else notices — an env var spelled one way in the YAML
and another in the script silently disables an input, and the run is green. These tests are the
thing that notices.
"""

from __future__ import annotations

import json
import pathlib
import re

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTION_TEXT = (ROOT / "action.yml").read_text()
ACTION = yaml.safe_load(ACTION_TEXT)
STEPS = ACTION["runs"]["steps"]

# Environment variables a step sets for something other than the script it runs. Each needs a
# reason, because the default assumption — "set but never read" — is a bug.
PASS_THROUGH = {
    # Read by the AWS CLI and SDK inside the script's own subprocesses, never by the script.
    "AWS_REGION",
}

SCRIPTS = ROOT / "scripts"


def scripts_reachable_from(names: list[str]) -> list[pathlib.Path]:
    """Every script a step can end up running, not only the one it names.

    A step that runs `terragrunt-changed-files.sh` ends in `deploy-terragrunt.sh`, which
    ends in `terragrunt-run.sh`. Following only the first hop would report every variable
    the last one reads as "set but never read" — the exact false alarm that teaches people
    to add things to PASS_THROUGH until the test means nothing.
    """
    seen: set[str] = set()
    queue = list(names)
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        path = resolve(name)
        if path is None:
            continue
        queue.extend(re.findall(r"([A-Za-z0-9_.-]+\.sh)", path.read_text()))
    return [p for p in (resolve(n) for n in sorted(seen)) if p is not None]


def resolve(name: str) -> pathlib.Path | None:
    """`scripts/` or `scripts/lib/`. The shared helpers are sourced by every script."""
    for candidate in (SCRIPTS / name, SCRIPTS / "lib" / name):
        if candidate.is_file():
            return candidate
    return None


def steps_running_scripts() -> list[tuple[dict, list[pathlib.Path]]]:
    out = []
    for step in STEPS:
        names = re.findall(r"scripts/([A-Za-z0-9_.-]+\.sh)", step.get("run", ""))
        if names:
            out.append((step, scripts_reachable_from(names)))
    return out


def test_every_script_the_action_names_exists():
    for step in STEPS:
        for name in re.findall(r"scripts/([A-Za-z0-9_.-]+\.(?:sh|py))", step.get("run", "")):
            assert (SCRIPTS / name).is_file(), f"{step.get('name')} runs a missing {name}"


def test_every_output_points_at_a_real_step():
    ids = {step["id"] for step in STEPS if "id" in step}
    for key, spec in ACTION["outputs"].items():
        for referenced in re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs", spec["value"]):
            assert referenced in ids, f"output {key} references unknown step id {referenced!r}"


def test_every_env_var_a_step_sets_is_actually_read():
    """The silent-failure joint: `KEY_PREFIX` in the YAML and `KEYPREFIX` in the script is a
    green run in which an input does nothing at all."""
    unread = []
    for step, scripts in steps_running_scripts():
        body = "\n".join(s.read_text() for s in scripts) + step.get("run", "")
        for name in step.get("env", {}):
            if name in PASS_THROUGH:
                continue
            # `tremvok::require NAME` reads the variable by indirection (`${!name}`), so the
            # name appears bare rather than after a `$`. Without this the test reports every
            # required-but-not-otherwise-interpolated variable as dead, and the fix people
            # reach for is an exemption, which is how the check stops meaning anything.
            read_patterns = (
                rf"\$\{{?{re.escape(name)}\b",
                rf"\$\{{{re.escape(name)}[:#%/-]",
                rf"tremvok::require\s+{re.escape(name)}\b",
            )
            if not any(re.search(pattern, body) for pattern in read_patterns):
                unread.append(f"{step.get('name')!r} sets {name}, which nothing reads")
    assert not unread, "\n".join(unread)


def test_every_declared_input_is_used():
    for name in ACTION["inputs"]:
        assert f"inputs.{name}" in ACTION_TEXT, f"input {name!r} is declared and never used"


def test_every_step_that_runs_a_script_declares_bash():
    # A composite action step without `shell:` fails at load time on some runners and defaults
    # differently on others; the scripts are bash and rely on it.
    for step, _ in steps_running_scripts():
        assert step.get("shell") == "bash", f"{step.get('name')} does not declare shell: bash"


def test_every_input_and_output_is_documented_in_the_reference():
    """The reference is docs/action-reference.md, NOT the README.

    The README is rendered verbatim on the Marketplace with no nav and no search, so
    scripts/lint_docs.py holds it to an action profile that bans a full `## Inputs` table
    and caps it at 120 lines. The README carries the most-used inputs and links out; the
    generated reference is where every input has to appear, and this test is what notices
    when the committed page has gone stale against action.yml.
    """
    reference = (ROOT / "docs" / "action-reference.md").read_text()
    undocumented = [n for n in ACTION["inputs"] if f"`{n}`" not in reference]
    assert not undocumented, f"inputs missing from docs/action-reference.md: {undocumented}"
    missing_outputs = [n for n in ACTION["outputs"] if f"`{n}`" not in reference]
    assert not missing_outputs, f"outputs missing from docs/action-reference.md: {missing_outputs}"


def test_notification_steps_run_even_when_the_deploy_failed():
    """A deploy that failed is exactly when the humans most need telling. A notification step
    without `always()` is skipped the moment anything upstream goes red."""
    for step in STEPS:
        name = step.get("name", "")
        if name.startswith("Notify") or name.startswith("Record"):
            assert "always()" in step.get("if", ""), f"{name} is not gated on always()"


@pytest.mark.parametrize("script", sorted((ROOT / "scripts").glob("*.sh")))
def test_every_script_fails_closed_and_is_executable(script):
    assert script.stat().st_mode & 0o111, f"{script.name} is not executable"
    text = script.read_text()
    assert "set -euo pipefail" in text, f"{script.name} does not set -euo pipefail"
    if script.name != "lib":
        assert text.startswith("#!/usr/bin/env bash"), f"{script.name} has no bash shebang"


@pytest.mark.parametrize(
    ("step_name", "gating_input"),
    [
        ("Assume the deployment role", "aws-role-to-assume"),
        ("Sign in to Azure", "azure-client-id"),
        ("Federate with Google Cloud", "gcp-workload-identity-provider"),
    ],
)
def test_the_cloud_logins_are_gated_on_their_input_and_not_on_a_target(step_name, gating_input):
    """The terragrunt target is provider-agnostic, and these three steps are what let it say so.

    Gating one of them on `inputs.target == '<something>'` would silently drop terragrunt from
    it, and the symptom is not a missing input — it is a plan that reads state perfectly well
    and then dies inside a provider, once per stack, with a message naming a generated file.
    That is the failure this parametrisation exists to keep from coming back, so the assertion
    is on the ABSENCE of a target check rather than on the presence of the input.
    """
    step = next((s for s in STEPS if s.get("name") == step_name), None)
    assert step is not None, f"the step {step_name!r} is gone; the credential path changed"
    condition = step.get("if", "")
    assert f"inputs.{gating_input} != ''" in condition, (
        f"{step_name} is no longer gated on {gating_input} being set"
    )
    assert "inputs.target ==" not in condition, (
        f"{step_name} is gated on a target. Every target that needs this credential now has "
        f"to be listed there, and the one that will be forgotten is terragrunt."
    )
    # The applicability map has to agree, or the validator refuses the input on a target the
    # step would happily have served.
    targets = json.loads((SCRIPTS / "lib" / "input-targets.json").read_text())
    assert "terragrunt" in targets["inputs"][gating_input]["targets"], (
        f"{gating_input} does not apply to terragrunt in input-targets.json, so "
        f"validate-inputs.sh refuses it there"
    )
