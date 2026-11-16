"""Typer command line of the custom quality-gate checks."""

from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import Annotated

import typer

from quality_gate.ai_review.errors import AIReviewError, ConfigurationError
from quality_gate.ai_review.llm import ChatClient, UrllibTransport
from quality_gate.ai_review.report import (
    FailOn,
    ReviewResult,
    github_annotations,
    render_markdown,
    render_text,
)
from quality_gate.ai_review.review import review
from quality_gate.ai_review.sources import candidate_paths, repository_root, select_sources
from quality_gate.ai_review.styleguide import find_styleguide, load_styleguide

API_KEY_VARIABLE = "QUALITY_GATE_AI_API_KEY"
CURRENT_DIRECTORY = Path()
DEFAULT_BASE_URL = "https://api.openai.com/v1"

EXIT_FINDINGS = 1
EXIT_CONFIGURATION = 2
EXIT_PROVIDER = 3

app = typer.Typer(
    name="quality-gate",
    help="Custom quality-gate checks of prefeitura-rio/actions.",
    no_args_is_help=True,
    add_completion=False,
    pretty_exceptions_enable=False,
)


@app.callback()
def _root() -> None:
    """Run the custom quality-gate checks of prefeitura-rio/actions."""


def _write(path: Path | None, content: str) -> None:
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_text(content, encoding="utf-8")


def _emit(text: str, *, error: bool, github: bool) -> None:
    """Print ``text``, which may carry model output.

    In GitHub mode everything goes to stdout, in order, between
    ``::stop-commands::`` markers with a random token, so no line of model
    output is processed as a workflow command.
    """
    if not github:
        typer.echo(text, err=error, nl=False)
        return
    token = secrets.token_hex(16)
    typer.echo(f"::stop-commands::{token}")
    typer.echo(text, nl=False)
    typer.echo(f"::{token}::")


def _relative(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path)


def _run(
    *,
    working_directory: Path,
    styleguide_path: Path | None,
    base_ref: str,
    model: str,
    base_url: str,
    timeout: float,
    max_files: int,
    max_file_bytes: int,
    max_request_chars: int,
    max_styleguide_chars: int,
) -> ReviewResult:
    client = ChatClient(
        base_url=base_url,
        api_key=os.environ.get(API_KEY_VARIABLE, ""),
        model=model,
        transport=UrllibTransport(),
        timeout=timeout,
    )
    root = repository_root(working_directory)
    styleguide = load_styleguide(
        find_styleguide(working_directory, root, styleguide_path),
        max_styleguide_chars,
    )
    selection = select_sources(
        root,
        candidate_paths(working_directory, base_ref),
        max_files,
        max_file_bytes,
    )
    parsed = (
        review(styleguide, selection.files, client, max_request_chars) if selection.files else None
    )
    return ReviewResult(
        styleguide=_relative(styleguide.path, root),
        styleguide_truncated=styleguide.truncated,
        reviewed=tuple(source.path for source in selection.files),
        skipped=selection.skipped,
        findings=parsed.findings if parsed is not None else (),
        discarded=parsed.discarded if parsed is not None else 0,
    )


@app.command("ai-review")
def ai_review(
    working_directory: Annotated[
        Path,
        typer.Option(help="Project directory to review.", file_okay=False),
    ] = CURRENT_DIRECTORY,
    styleguide: Annotated[
        Path | None,
        typer.Option(
            help="Styleguide file, relative to the working directory. Default: the first "
            "STYLEGUIDE.md (or style-guide.md, style_guide.md, STYLEGUIDE) found in the "
            "project or repository root, docs/ or .github/.",
        ),
    ] = None,
    base_ref: Annotated[
        str,
        typer.Option(
            help="Review only the files changed since the merge base with this branch. "
            "Empty reviews every tracked file.",
        ),
    ] = "",
    model: Annotated[
        str,
        typer.Option(help="Model name.", envvar="QUALITY_GATE_AI_MODEL"),
    ] = "",
    base_url: Annotated[
        str,
        typer.Option(
            help="Base URL of an OpenAI-compatible API.",
            envvar="QUALITY_GATE_AI_BASE_URL",
        ),
    ] = DEFAULT_BASE_URL,
    fail_on: Annotated[
        FailOn,
        typer.Option(help="Lowest finding severity that fails the check."),
    ] = FailOn.ERROR,
    timeout: Annotated[
        float,
        typer.Option(help="Seconds to wait for each model request.", min=1),
    ] = 120.0,
    max_files: Annotated[
        int,
        typer.Option(help="Maximum number of files reviewed.", min=1),
    ] = 50,
    max_file_bytes: Annotated[
        int,
        typer.Option(help="Files larger than this are not reviewed.", min=1),
    ] = 100_000,
    max_request_chars: Annotated[
        int,
        typer.Option(help="Characters of source code sent per model request.", min=1),
    ] = 60_000,
    max_styleguide_chars: Annotated[
        int,
        typer.Option(help="The styleguide is truncated to this many characters.", min=1),
    ] = 40_000,
    summary_file: Annotated[
        Path | None,
        typer.Option(help="Write a Markdown summary to this file.", dir_okay=False),
    ] = None,
    error_file: Annotated[
        Path | None,
        typer.Option(
            help="Write the failure report to this file.",
            envvar="QUALITY_GATE_ERROR_FILE",
            dir_okay=False,
        ),
    ] = None,
    github_annotations_enabled: Annotated[
        bool,
        typer.Option(
            "--github-annotations/--no-github-annotations",
            help="GitHub Actions mode: annotate each finding and print the report to "
            "stdout with workflow commands disabled around it.",
        ),
    ] = False,
) -> None:
    """Flag code that breaks the repository styleguide and suggest fixes.

    The API key is read from the QUALITY_GATE_AI_API_KEY environment variable.
    Exit codes: 0 passed, 1 findings at or above --fail-on, 2 invalid input,
    3 model provider failure.
    """
    try:
        result = _run(
            working_directory=working_directory,
            styleguide_path=styleguide,
            base_ref=base_ref,
            model=model,
            base_url=base_url,
            timeout=timeout,
            max_files=max_files,
            max_file_bytes=max_file_bytes,
            max_request_chars=max_request_chars,
            max_styleguide_chars=max_styleguide_chars,
        )
    except AIReviewError as error:
        _write(error_file, f"{error}\n")
        _emit(f"Error: {error}\n", error=True, github=github_annotations_enabled)
        code = EXIT_CONFIGURATION if isinstance(error, ConfigurationError) else EXIT_PROVIDER
        raise typer.Exit(code) from error

    report = render_text(result, fail_on)
    _write(summary_file, render_markdown(result, fail_on))
    if github_annotations_enabled:
        for command in github_annotations(result):
            typer.echo(command)
    failing = result.failing(fail_on)
    if failing:
        _write(error_file, report)
        _emit(report, error=True, github=github_annotations_enabled)
        raise typer.Exit(EXIT_FINDINGS)
    _emit(report, error=False, github=github_annotations_enabled)


def main() -> None:
    """Console script entry point."""
    app()
