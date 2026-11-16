from __future__ import annotations

import json
from pathlib import Path

import pytest

from quality_gate.ai_review.errors import ResponseFormatError
from quality_gate.ai_review.review import (
    Finding,
    Severity,
    batches,
    parse_findings,
    render_file,
    review,
    system_prompt,
    user_prompt,
)
from quality_gate.ai_review.sources import SourceFile
from quality_gate.ai_review.styleguide import Styleguide

SOURCES = (
    SourceFile(path="app/main.py", text="import os\nprint(os.name)\n"),
    SourceFile(path="app/util.py", text="X = 1\n"),
)
STYLEGUIDE = Styleguide(
    path=Path("STYLEGUIDE.md"),
    text="- Never use print {braces}.",
    truncated=False,
)


def _answer(*findings: object) -> str:
    return json.dumps({"findings": list(findings)})


def _valid(**overrides: object) -> dict[str, object]:
    finding: dict[str, object] = {
        "path": "app/main.py",
        "line": 2,
        "severity": "error",
        "rule": "no-print",
        "message": "print is forbidden",
        "suggestion": "logger.info(os.name)",
    }
    finding.update(overrides)
    return finding


def test_system_prompt_carries_the_styleguide_verbatim() -> None:
    prompt = system_prompt(STYLEGUIDE)

    assert "<styleguide>\n- Never use print {braces}.\n</styleguide>" in prompt
    assert '{"findings": []}' in prompt


def test_files_are_rendered_with_line_numbers() -> None:
    assert render_file(SOURCES[0]) == (
        '<file path="app/main.py">\n1| import os\n2| print(os.name)\n</file>'
    )
    assert user_prompt(SOURCES).count("<file path=") == 2


def test_parses_valid_findings() -> None:
    parsed = parse_findings(_answer(_valid()), SOURCES)

    assert parsed.discarded == 0
    assert parsed.findings == (
        Finding(
            path="app/main.py",
            line=2,
            severity=Severity.ERROR,
            rule="no-print",
            message="print is forbidden",
            suggestion="logger.info(os.name)",
        ),
    )


def test_parses_answers_wrapped_in_code_fences_or_prose() -> None:
    fenced = f"```json\n{_answer(_valid())}\n```"
    prose = f"Here is the review:\n{_answer(_valid())}\nDone."

    assert len(parse_findings(fenced, SOURCES).findings) == 1
    assert len(parse_findings(prose, SOURCES).findings) == 1


def test_discards_findings_outside_reviewed_files_and_lines() -> None:
    answer = _answer(
        _valid(path="app/other.py"),
        _valid(line=3),
        _valid(line=0),
        _valid(line="2"),
        _valid(line=True),
        _valid(severity="critical"),
        _valid(message=""),
        _valid(severity="WARNING", rule=None),
        "not an object",
    )

    parsed = parse_findings(answer, SOURCES)

    assert parsed.discarded == 8
    assert [(finding.severity, finding.rule) for finding in parsed.findings] == [
        (Severity.WARNING, "styleguide"),
    ]


@pytest.mark.parametrize("answer", ["no json here", "[]", '{"result": []}', '{"findings": {}}'])
def test_rejects_answers_without_a_findings_list(answer: str) -> None:
    with pytest.raises(ResponseFormatError):
        _ = parse_findings(answer, SOURCES)


def test_batches_respect_the_request_size() -> None:
    sizes = [len(render_file(source)) for source in SOURCES]

    assert batches(SOURCES, sum(sizes)) == [list(SOURCES)]
    assert batches(SOURCES, sizes[0]) == [[SOURCES[0]], [SOURCES[1]]]
    assert batches(SOURCES, 1) == [[SOURCES[0]], [SOURCES[1]]]


class _ScriptedModel:
    def __init__(self, answers: list[str]) -> None:
        self.answers: list[str] = answers
        self.users: list[str] = []

    def complete(self, system: str, user: str) -> str:
        assert "<styleguide>" in system
        self.users.append(user)
        return self.answers.pop(0)


def test_review_merges_batches_and_sorts_findings() -> None:
    model = _ScriptedModel(
        [
            _answer(_valid(line=2, rule="b"), _valid(line=1, rule="a")),
            _answer(_valid(path="app/util.py", line=1, severity="warning"), _valid(path="x.py")),
        ],
    )

    result = review(STYLEGUIDE, SOURCES, model, max_request_chars=1)

    assert len(model.users) == 2
    assert result.discarded == 1
    assert [(finding.path, finding.line) for finding in result.findings] == [
        ("app/main.py", 1),
        ("app/main.py", 2),
        ("app/util.py", 1),
    ]
