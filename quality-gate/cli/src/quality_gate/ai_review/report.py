"""Render AI review results for logs, summaries and GitHub annotations."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

from quality_gate.ai_review.review import Finding, Severity

if TYPE_CHECKING:
    from collections.abc import Sequence

SUMMARY_SUGGESTION_LIMIT = 1000


class FailOn(StrEnum):
    """Lowest severity that fails the check."""

    ERROR = "error"
    WARNING = "warning"
    NEVER = "never"


@dataclass(frozen=True, slots=True)
class ReviewResult:
    """Everything the review produced."""

    styleguide: str
    styleguide_truncated: bool
    reviewed: tuple[str, ...]
    skipped: tuple[tuple[str, str], ...]
    findings: tuple[Finding, ...]
    discarded: int

    def failing(self, fail_on: FailOn) -> tuple[Finding, ...]:
        """Return the findings at or above ``fail_on``."""
        if fail_on is FailOn.NEVER:
            return ()
        if fail_on is FailOn.WARNING:
            return self.findings
        return tuple(finding for finding in self.findings if finding.severity is Severity.ERROR)


def _counts(findings: Sequence[Finding]) -> str:
    errors = sum(1 for finding in findings if finding.severity is Severity.ERROR)
    warnings = len(findings) - errors
    return f"{errors} error(s), {warnings} warning(s)"


def _notes(result: ReviewResult) -> list[str]:
    notes: list[str] = []
    if result.styleguide_truncated:
        notes.append("The styleguide was truncated to the configured size limit.")
    notes.extend(f"Not reviewed: {path} ({reason})." for path, reason in result.skipped)
    if result.discarded:
        notes.append(
            f"{result.discarded} model finding(s) were discarded because they did not point "
            "to a reviewed file and line.",
        )
    return notes


def render_text(result: ReviewResult, fail_on: FailOn) -> str:
    """Plain-text report for logs and the portable error file."""
    failing = result.failing(fail_on)
    lines: list[str] = []
    if failing:
        lines.append(
            f"Error: AI review found code outside the styleguide ({_counts(result.findings)}).",
        )
    else:
        lines.append(
            f"AI review passed: {len(result.reviewed)} file(s) reviewed against "
            f"{result.styleguide} ({_counts(result.findings)}).",
        )
    for finding in result.findings:
        lines.append("")
        lines.append(
            f"{finding.path}:{finding.line}: {finding.severity.value} [{finding.rule}] "
            f"{finding.message}",
        )
        if finding.suggestion:
            lines.extend(f"    {line}" for line in finding.suggestion.splitlines())
    notes = _notes(result)
    if notes:
        lines.append("")
        lines.extend(notes)
    if failing:
        lines.extend(
            [
                "",
                "How to fix it:",
                f"Apply the suggestions above, following the rules in {result.styleguide}.",
            ],
        )
    return "\n".join(lines) + "\n"


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", "<br>")


def render_markdown(result: ReviewResult, fail_on: FailOn) -> str:
    """Markdown job summary."""
    failing = result.failing(fail_on)
    status = "❌ Failed" if failing else "✅ Passed"
    lines = [
        "# AI Review",
        "",
        f"**Status:** {status}",
        f"**Styleguide:** `{result.styleguide}`",
        f"**Files reviewed:** {len(result.reviewed)}",
        f"**Findings:** {_counts(result.findings)}",
    ]
    if result.findings:
        lines.extend(
            [
                "",
                "| Location | Severity | Rule | Problem | Suggestion |",
                "|---|---|---|---|---|",
            ],
        )
        lines.extend(
            f"| `{finding.path}:{finding.line}` | {finding.severity.value} "
            f"| {_cell(finding.rule)} | {_cell(finding.message)} "
            f"| {_cell(finding.suggestion[:SUMMARY_SUGGESTION_LIMIT])} |"
            for finding in result.findings
        )
    notes = _notes(result)
    if notes:
        lines.append("")
        lines.extend(f"- {note}" for note in notes)
    return "\n".join(lines) + "\n"


def _escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(value: str) -> str:
    return _escape_data(value).replace(":", "%3A").replace(",", "%2C")


def github_annotations(result: ReviewResult) -> list[str]:
    """GitHub workflow commands that annotate each finding on its file and line."""
    commands: list[str] = []
    for finding in result.findings:
        level = "error" if finding.severity is Severity.ERROR else "warning"
        message = finding.message
        if finding.suggestion:
            message = f"{message}\n\nSuggestion:\n{finding.suggestion}"
        commands.append(
            f"::{level} file={_escape_property(finding.path)},line={finding.line},"
            f"title={_escape_property(f'AI review: {finding.rule}')}::{_escape_data(message)}",
        )
    return commands
