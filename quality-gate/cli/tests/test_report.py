from __future__ import annotations

from quality_gate.ai_review.report import (
    FailOn,
    ReviewResult,
    github_annotations,
    render_markdown,
    render_text,
)
from quality_gate.ai_review.review import Finding, Severity

ERROR = Finding(
    path="app/main.py",
    line=2,
    severity=Severity.ERROR,
    rule="no-print",
    message="print is forbidden",
    suggestion="logger.info(x)\nreturn",
)
WARNING = Finding(
    path="app/a,b.py",
    line=7,
    severity=Severity.WARNING,
    rule="naming: short | vague",
    message="100% unclear\nname",
    suggestion="",
)


def _result(*findings: Finding) -> ReviewResult:
    return ReviewResult(
        styleguide="STYLEGUIDE.md",
        styleguide_truncated=False,
        reviewed=("app/main.py", "app/a,b.py"),
        skipped=(("big.py", "larger than 10 bytes"),),
        findings=findings,
        discarded=1,
    )


def test_fail_on_thresholds() -> None:
    result = _result(ERROR, WARNING)

    assert result.failing(FailOn.ERROR) == (ERROR,)
    assert result.failing(FailOn.WARNING) == (ERROR, WARNING)
    assert result.failing(FailOn.NEVER) == ()
    assert _result(WARNING).failing(FailOn.ERROR) == ()


def test_failure_report_lists_locations_suggestions_and_remediation() -> None:
    report = render_text(_result(ERROR, WARNING), FailOn.ERROR)

    assert report == (
        "Error: AI review found code outside the styleguide (1 error(s), 1 warning(s)).\n"
        "\n"
        "app/main.py:2: error [no-print] print is forbidden\n"
        "    logger.info(x)\n"
        "    return\n"
        "\n"
        "app/a,b.py:7: warning [naming: short | vague] 100% unclear\nname\n"
        "\n"
        "Not reviewed: big.py (larger than 10 bytes).\n"
        "1 model finding(s) were discarded because they did not point to a reviewed file "
        "and line.\n"
        "\n"
        "How to fix it:\n"
        "Apply the suggestions above, following the rules in STYLEGUIDE.md.\n"
    )


def test_passing_report() -> None:
    report = render_text(_result(WARNING), FailOn.ERROR)

    assert report.startswith(
        "AI review passed: 2 file(s) reviewed against STYLEGUIDE.md (0 error(s), 1 warning(s)).",
    )
    assert "How to fix it" not in report


def test_markdown_summary_escapes_table_cells() -> None:
    summary = render_markdown(_result(ERROR, WARNING), FailOn.WARNING)

    assert "**Status:** ❌ Failed" in summary
    assert (
        "| `app/main.py:2` | error | no-print | print is forbidden | logger.info(x)<br>return |"
        in (summary)
    )
    assert "naming: short \\| vague" in summary
    assert "- Not reviewed: big.py (larger than 10 bytes)." in summary
    assert "**Status:** ✅ Passed" in render_markdown(_result(), FailOn.ERROR)


def test_github_annotations_escape_workflow_command_syntax() -> None:
    assert github_annotations(_result(ERROR, WARNING)) == [
        (
            "::error file=app/main.py,line=2,title=AI review%3A no-print::"
            "print is forbidden%0A%0ASuggestion:%0Alogger.info(x)%0Areturn"
        ),
        (
            "::warning file=app/a%2Cb.py,line=7,title=AI review%3A naming%3A short | vague::"
            "100%25 unclear%0Aname"
        ),
    ]
