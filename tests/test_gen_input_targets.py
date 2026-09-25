"""The generator's own behaviour, exercised in-process.

`tests/test_input_targets.py` proves the *committed* map is fresh, and it does that the way
CI does: by running the script in a child process. That is the right end-to-end gate and it
stays. What it cannot do is distinguish the ways `targets_for()` can be wrong — a description
that merely looks like a marker, a marker naming a target that does not exist, a stale file
that `--check` fails to notice. Those branches decide which inputs a target accepts, so a
typo in a description could silently narrow an input's applicability and the run would still
be green.

These tests call the functions directly. No subprocess, no network, and nothing writes to the
repository tree: the `main()` tests point `ROOT`/`OUT` at a tmp_path.
"""

from __future__ import annotations

import json
import pathlib
import re
import runpy
import shutil
import subprocess  # nosec B404
import sys

import gen_input_targets as gen
import pytest
import yaml

ALL_TARGETS = [
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
ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTION = yaml.safe_load((ROOT / "action.yml").read_text(encoding="utf-8"))


@pytest.fixture
def sandbox(monkeypatch, tmp_path):
    """Point the generator's output at a tmp_path, restored after the test.

    `ROOT` has to move with `OUT`, because `main()` prints `OUT.relative_to(ROOT)` and a
    tmp path is not under the repository root — patching only `OUT` swaps the assertion
    being tested for a `ValueError`.
    """
    out = tmp_path / "input-targets.json"
    monkeypatch.setattr(gen, "ROOT", tmp_path)
    monkeypatch.setattr(gen, "OUT", out)
    return out


# --- targets_for: which inputs a target accepts ------------------------------------------


def test_the_module_agrees_with_the_target_list_the_action_documents():
    """Not a comparison against a literal: the target names are parsed back out of the
    `target` input's own description in action.yml. A target added to the action and not to
    TARGETS would leave every one of its inputs silently scoped to all five."""
    documented = set(
        re.findall(r"^ {2}(\S+) {2,}\S", ACTION["inputs"]["target"]["description"], re.M)
    )
    assert documented, "the target input's description no longer lists its values"
    assert set(gen.TARGETS) == documented
    assert gen.TARGETS == ALL_TARGETS  # order is load-bearing: it is the JSON's order


def test_a_marker_naming_one_target_scopes_the_input_to_it():
    assert gen.targets_for("github-pages: the site directory.") == ["github-pages"]


def test_a_marker_may_name_several_targets_and_keeps_the_declared_order():
    """Shared inputs exist. The order is the description's, not TARGETS', so a reader of
    the generated JSON sees the list the author wrote."""
    assert gen.targets_for("s3-cloudfront, lambda-zip: the bucket.") == [
        "s3-cloudfront",
        "lambda-zip",
    ]


def test_prose_that_is_not_lowercase_is_not_a_marker():
    """The docstring's own example. `Post-deploy:` reads like a marker and is not one."""
    assert gen.targets_for("Post-deploy: the URL that must answer.") == ALL_TARGETS


@pytest.mark.parametrize(
    "description",
    [
        "post-deploy: the URL that must answer.",
        "github-pages, nope: a real target and a typo.",
        "s3-clodfront: one transposed letter.",
    ],
)
def test_a_lowercase_prefix_that_is_not_a_target_is_still_prose(description):
    """The load-bearing case. Syntactically a marker, semantically not one — so it applies
    everywhere rather than to nothing, and one unknown name discards the whole list instead
    of being quietly dropped. Without this check a typo in a description would narrow an
    input's applicability and the runtime validator would refuse a perfectly valid input."""
    assert gen.targets_for(description) == ALL_TARGETS


@pytest.mark.parametrize("description", ["", None])
def test_an_absent_description_applies_everywhere(description):
    assert gen.targets_for(description) == ALL_TARGETS


def test_only_the_first_line_can_carry_the_marker():
    """Bounded to one line, so a description whose body contains a colon is not re-read as
    a target list."""
    assert gen.targets_for("s3-cloudfront: the bucket.\ndocs: not a second marker.") == [
        "s3-cloudfront"
    ]
    assert gen.targets_for("The bucket.\ndocs: not a marker either.") == ALL_TARGETS


def test_the_marker_tolerates_spacing_around_its_punctuation():
    assert gen.targets_for("  github-pages , s3-cloudfront : padded.  ") == [
        "github-pages",
        "s3-cloudfront",
    ]


def test_the_caller_gets_its_own_list_and_cannot_corrupt_the_target_set():
    """`targets_for` hands back a copy. build() calls it once per input, so a returned
    alias of TARGETS would let one input's list mutate every later input's."""
    returned = gen.targets_for("")
    returned.append("not-a-target")
    assert gen.TARGETS == ALL_TARGETS


@pytest.mark.parametrize("description", ["   ", "\n\n", "\t", " \n "])
def test_a_whitespace_only_description_applies_to_every_target(description):
    """A whitespace-only description used to raise IndexError and take the generator, and
    with it CI, down: `"   "` is truthy, strips to `""`, and `"".splitlines()` is empty, so
    indexing the first line blew up. No marker means no scoping, which means every target."""
    assert gen.targets_for(description) == ALL_TARGETS


# --- build: the map itself ----------------------------------------------------------------


def test_the_selector_is_not_an_entry_in_its_own_map():
    """`target` chooses; it is not chosen against. Listing it would make the validator
    check the selector's applicability to itself."""
    data = gen.build()
    assert list(data) == ["targets", "inputs"]
    assert data["targets"] == ALL_TARGETS
    assert "target" not in data["inputs"]
    assert set(data["inputs"]) == set(ACTION["inputs"]) - {"target"}


def test_every_entry_carries_a_string_default_and_a_non_empty_target_list():
    """The validator compares a received value against `default` as a string. A non-string
    here (a YAML bool, an unquoted number) would compare unequal to every runner value."""
    for name, spec in gen.build()["inputs"].items():
        assert isinstance(spec["default"], str), name
        assert spec["targets"], name
        assert set(spec["targets"]) <= set(ALL_TARGETS), name


def test_build_stringifies_defaults_and_treats_a_missing_one_as_empty(monkeypatch, tmp_path):
    """action.yml quotes every default today, so these two conversions are unobservable
    against the real file — and would break silently the day someone writes `default: 3`."""
    action = tmp_path / "action.yml"
    action.write_text(
        "inputs:\n"
        "  target:\n"
        "    description: 'the selector'\n"
        "  retries:\n"
        "    description: 'github-pages: how many times.'\n"
        "    default: 3\n"
        "  token:\n"
        "    description: 'no default at all.'\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(gen, "ACTION", action)

    data = gen.build()

    assert "target" not in data["inputs"]
    assert data["inputs"]["retries"] == {"targets": ["github-pages"], "default": "3"}
    assert data["inputs"]["token"] == {"targets": ALL_TARGETS, "default": ""}


# --- render: what --check compares ---------------------------------------------------------


def test_render_preserves_action_yml_declaration_order():
    """`render() == render()` would hold for any pure function, including one returning "".
    What actually makes `--check` stable is that the key order comes from action.yml rather
    than from a set or a sort, so this asserts that order instead of self-equality."""
    rendered = list(json.loads(gen.render())["inputs"])
    declared = [name for name in ACTION["inputs"] if name != "target"]
    assert rendered == declared


def test_render_ends_with_a_newline():
    """Without it every checkout shows a one-line diff and people learn to ignore --check."""
    assert gen.render().endswith("\n")


def test_render_round_trips_to_build_in_action_yml_order():
    """`sort_keys=False`: the JSON reads in the order action.yml declares, so a reviewer can
    diff the two side by side."""
    parsed = json.loads(gen.render())
    assert parsed == gen.build()
    assert list(parsed["inputs"]) == [n for n in ACTION["inputs"] if n != "target"]


# --- main: the CI gate ----------------------------------------------------------------------


def test_check_passes_when_the_committed_file_matches(sandbox, capsys):
    sandbox.write_text(gen.render(), encoding="utf-8")

    assert gen.main(["--check"]) == 0
    assert "up to date" in capsys.readouterr().out


def test_check_fails_when_the_file_is_stale(sandbox, capsys):
    """A --check that cannot return 1 is decoration."""
    sandbox.write_text("{}\n", encoding="utf-8")

    assert gen.main(["--check"]) == 1
    assert "is stale" in capsys.readouterr().out


def test_check_fails_when_the_file_is_missing(sandbox, capsys):
    """Absent is stale, not "nothing to compare". The generated file is not optional."""
    assert not sandbox.exists()

    assert gen.main(["--check"]) == 1
    assert "gen_input_targets.py" in capsys.readouterr().out


def test_the_stale_message_names_the_command_that_fixes_it(sandbox, capsys):
    sandbox.write_text("{}\n", encoding="utf-8")
    gen.main(["--check"])

    assert "Run: python scripts/gen_input_targets.py" in capsys.readouterr().out


def test_running_without_check_writes_the_file_and_reports_success(sandbox, capsys):
    assert gen.main([]) == 0
    assert sandbox.read_text(encoding="utf-8") == gen.render()
    assert "wrote" in capsys.readouterr().out


def test_generating_then_checking_is_a_fixed_point(sandbox):
    """The whole contract in one line: what the generator writes is what --check accepts."""
    assert gen.main([]) == 0
    assert gen.main(["--check"]) == 0


def test_running_as_a_program_exits_with_what_main_returns(monkeypatch):
    """The `__main__` guard passes the return code through. An entrypoint that swallowed it
    would make a stale file a green CI run, which is the one failure this script exists to
    prevent. Compared against `main()` rather than hardcoded 0, so this asserts propagation
    and not the freshness of the committed file — that is the subprocess suite's job."""
    monkeypatch.setattr(sys, "argv", ["gen_input_targets.py", "--check"])

    with pytest.raises(SystemExit) as exit_info:
        runpy.run_module("gen_input_targets", run_name="__main__")

    assert exit_info.value.code == 0


def test_a_stale_file_makes_the_program_exit_non_zero(tmp_path):
    """The test above only proves the guard exits; against the committed file `main`
    returns 0, so it passes just as happily with the guard replaced by `sys.exit(0)` and a
    swallowed failure would reach CI green. That is the one failure this script exists to
    prevent, so it gets asserted on the path where the code is not zero.

    A real child process, because a process exit code is what CI reads. The script derives
    ROOT from its own location, so a copied tree gives it a sandbox with no monkeypatching.
    """
    (tmp_path / "scripts" / "lib").mkdir(parents=True)
    shutil.copy(ROOT / "scripts" / "gen_input_targets.py", tmp_path / "scripts")
    shutil.copy(ROOT / "action.yml", tmp_path / "action.yml")
    (tmp_path / "scripts" / "lib" / "input-targets.json").write_text(
        '{"targets": [], "inputs": {}}\n', encoding="utf-8"
    )

    result = subprocess.run(  # nosec B603
        [sys.executable, str(tmp_path / "scripts" / "gen_input_targets.py"), "--check"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1, result.stdout + result.stderr
    assert "is stale" in result.stdout
