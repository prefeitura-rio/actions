"""Select the source files the AI review reads."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from quality_gate.ai_review.errors import ConfigurationError

REVIEWABLE_SUFFIXES: frozenset[str] = frozenset(
    {
        ".cjs",
        ".cts",
        ".go",
        ".js",
        ".jsx",
        ".mjs",
        ".mts",
        ".py",
        ".pyi",
        ".ts",
        ".tsx",
        ".vue",
    },
)
"""Suffixes of Go, Python and TypeScript/JavaScript sources."""

EXCLUDED_DIRECTORIES: frozenset[str] = frozenset(
    {
        ".git",
        ".next",
        ".nuxt",
        ".output",
        ".venv",
        "__pycache__",
        "build",
        "dist",
        "node_modules",
        "vendor",
    },
)
"""Directory names whose files are generated or third-party code."""


@dataclass(frozen=True, slots=True)
class SourceFile:
    """A source file, addressed by its repository-relative POSIX path."""

    path: str
    text: str


@dataclass(frozen=True, slots=True)
class SourceSelection:
    """Files to review and files left out, with the reason for each."""

    files: tuple[SourceFile, ...]
    skipped: tuple[tuple[str, str], ...]


def _git(working_directory: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(  # noqa: S603 - fixed git argv, no shell
            ["git", *arguments],  # noqa: S607 - git is resolved from PATH like the other checks
            cwd=working_directory,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as error:
        msg = "git is not installed or not on PATH."
        raise ConfigurationError(msg) from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit code {completed.returncode}"
        msg = f"git {' '.join(arguments)} failed: {detail}"
        raise ConfigurationError(msg)
    return completed.stdout


def repository_root(working_directory: Path) -> Path:
    """Return the root of the git repository containing ``working_directory``."""
    if not working_directory.is_dir():
        msg = f"Working directory '{working_directory}' does not exist."
        raise ConfigurationError(msg)
    return Path(_git(working_directory, "rev-parse", "--show-toplevel").strip())


def _resolve_base(working_directory: Path, base_ref: str) -> str:
    if base_ref.startswith("-"):
        msg = f"Invalid base reference '{base_ref}'."
        raise ConfigurationError(msg)
    for candidate in (base_ref, f"origin/{base_ref}"):
        try:
            _ = _git(
                working_directory,
                "rev-parse",
                "--verify",
                "--quiet",
                f"{candidate}^{{commit}}",
            )
        except ConfigurationError:
            continue
        return candidate
    msg = (
        f"Base reference '{base_ref}' was not found. Fetch it before the review "
        "(for example actions/checkout with fetch-depth: 0)."
    )
    raise ConfigurationError(msg)


def is_reviewable(path: str) -> bool:
    """Whether ``path`` is a Go, Python or TypeScript source outside generated folders."""
    pure = PurePosixPath(path)
    if pure.suffix.lower() not in REVIEWABLE_SUFFIXES:
        return False
    return not any(part in EXCLUDED_DIRECTORIES for part in pure.parts[:-1])


def candidate_paths(working_directory: Path, base_ref: str) -> list[str]:
    """List repository-relative paths below ``working_directory`` to review.

    With a base reference, only files added, copied, modified or renamed
    between the merge base and ``HEAD`` are listed. Without one, every tracked
    file is listed.
    """
    if base_ref:
        base = _resolve_base(working_directory, base_ref)
        output = _git(
            working_directory,
            "diff",
            "--name-only",
            "--diff-filter=ACMR",
            "-z",
            f"{base}...HEAD",
            "--",
            ".",
        )
    else:
        output = _git(working_directory, "ls-files", "--full-name", "-z", "--", ".")
    paths = sorted({path for path in output.split("\0") if path})
    return [path for path in paths if is_reviewable(path)]


def select_sources(
    root: Path,
    paths: list[str],
    max_files: int,
    max_file_bytes: int,
) -> SourceSelection:
    """Read up to ``max_files`` UTF-8 files of at most ``max_file_bytes`` bytes.

    A path whose symbolic links resolve outside ``root`` is skipped, so a
    tracked link cannot send a file from elsewhere on the runner to the model.
    """
    files: list[SourceFile] = []
    skipped: list[tuple[str, str]] = []
    resolved_root = root.resolve()
    for path in paths:
        absolute = root / path
        if len(files) >= max_files:
            skipped.append((path, f"over the limit of {max_files} files"))
            continue
        if not absolute.resolve().is_relative_to(resolved_root):
            skipped.append((path, "resolves outside the repository"))
            continue
        if not absolute.is_file():
            skipped.append((path, "not a regular file"))
            continue
        if absolute.stat().st_size > max_file_bytes:
            skipped.append((path, f"larger than {max_file_bytes} bytes"))
            continue
        try:
            text = absolute.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            skipped.append((path, "not UTF-8 text"))
            continue
        if not text.strip():
            continue
        files.append(SourceFile(path=path, text=text))
    return SourceSelection(files=tuple(files), skipped=tuple(skipped))
