"""No bats assertion may be written as a bare negation.

bats runs a test body under errexit, and bash exempts a command prefixed with `!` from it. So
`! grep -q secret "$log"` fails a test in exactly one position: the LAST line of the body, where
its status becomes the test function's return value. Anywhere else it observes nothing.

That makes a bare negation a trap for the next edit rather than a bug on the day it is written.
Every one in this suite was on the last line, and so worked; but appending one more assertion
below any of them would have turned it into a line that reads like a check and passes whatever
the log holds, with nothing reporting the change. Several of them assert that a secret never
reaches a log or an env file.

`refute` in tests/bats/helper.bash moves the inversion inside a function, so the call site is a
plain command that errexit acts on wherever it sits. A `[[ a == b ]]` negation is written as
`[[ a != b ]]` instead, which is a plain command too. This test keeps it that way.
"""

from __future__ import annotations

import pathlib
import re

BATS = pathlib.Path(__file__).resolve().parents[1] / "tests" / "bats"

#: A statement that begins with `!`. `refute() { ! "$@"; }` does not match: the line begins with
#: the function name, and inside the function the inversion is exactly what is wanted.
BARE_NEGATION = re.compile(r"^\s+!\s")


def bare_negations(path: pathlib.Path) -> list[str]:
    return [
        f"{path.name}:{number}: {line.strip()}"
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1)
        if BARE_NEGATION.match(line)
    ]


def test_the_suite_exists() -> None:
    # A glob that matched nothing would make the test below pass vacuously.
    assert len(list(BATS.glob("*.bats"))) > 10


def test_no_bats_assertion_is_a_bare_negation() -> None:
    offenders = [
        finding for path in sorted(BATS.glob("*.bats")) for finding in bare_negations(path)
    ]
    assert not offenders, (
        "A bare `!` only fails a bats test on the last line of its body; anywhere else errexit "
        "ignores it, so the assertion can never fail. Write `refute <command>` (tests/bats/"
        "helper.bash) or `[[ a != b ]]` instead:\n  " + "\n  ".join(offenders)
    )


def test_the_detector_sees_what_it_is_for(tmp_path: pathlib.Path) -> None:
    sample = tmp_path / "sample.bats"
    sample.write_text(
        '@test "x" {\n'
        '  ! grep -q secret "$STUB_LOG"\n'
        '  ! [[ "$output" == *secret* ]]\n'
        '  refute grep -q secret "$STUB_LOG"\n'
        '  [[ "$output" != *secret* ]]\n'
        "  if ! command -v jq >/dev/null; then skip; fi\n"
        "}\n"
        'refute() { ! "$@"; }\n',
        encoding="utf-8",
    )
    assert [finding.split(": ", 1)[1] for finding in bare_negations(sample)] == [
        '! grep -q secret "$STUB_LOG"',
        '! [[ "$output" == *secret* ]]',
    ]
