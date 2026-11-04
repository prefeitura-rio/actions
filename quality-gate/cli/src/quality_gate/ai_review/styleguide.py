"""Locate and load the repository styleguide."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from quality_gate.ai_review.errors import ConfigurationError

if TYPE_CHECKING:
    from pathlib import Path

STYLEGUIDE_NAMES: tuple[str, ...] = (
    "styleguide.md",
    "style-guide.md",
    "style_guide.md",
    "styleguide",
)
"""Accepted styleguide file names, compared case-insensitively."""

STYLEGUIDE_DIRECTORIES: tuple[str, ...] = (".", "docs", ".github")
"""Directories searched for a styleguide, in order, below each search root."""


@dataclass(frozen=True, slots=True)
class Styleguide:
    """Styleguide text sent to the model."""

    path: Path
    text: str
    truncated: bool


def _match_in_directory(directory: Path) -> Path | None:
    if not directory.is_dir():
        return None
    entries = {entry.name.lower(): entry for entry in sorted(directory.iterdir())}
    for name in STYLEGUIDE_NAMES:
        entry = entries.get(name)
        if entry is not None and entry.is_file():
            return entry
    return None


def find_styleguide(
    working_directory: Path,
    repository_root: Path,
    explicit: Path | None,
) -> Path:
    """Return the styleguide path.

    An explicit path is resolved against the working directory and must exist.
    Otherwise the working directory and then the repository root are searched
    for the names in ``STYLEGUIDE_NAMES`` inside ``STYLEGUIDE_DIRECTORIES``.
    """
    if explicit is not None:
        candidate = explicit if explicit.is_absolute() else working_directory / explicit
        if not candidate.is_file():
            msg = f"Styleguide file '{explicit}' does not exist."
            raise ConfigurationError(msg)
        return candidate

    roots = [working_directory]
    if repository_root.resolve() != working_directory.resolve():
        roots.append(repository_root)
    for root in roots:
        for directory in STYLEGUIDE_DIRECTORIES:
            match = _match_in_directory(root / directory)
            if match is not None:
                return match

    msg = (
        "No styleguide found. Add STYLEGUIDE.md to the project or repository root "
        "(or to docs/ or .github/), or set the styleguide input."
    )
    raise ConfigurationError(msg)


def load_styleguide(path: Path, max_chars: int) -> Styleguide:
    """Read the styleguide, truncating it to ``max_chars`` characters."""
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        msg = f"Styleguide file '{path}' is not valid UTF-8 text."
        raise ConfigurationError(msg) from error
    except OSError as error:
        msg = f"Styleguide file '{path}' could not be read: {error.strerror}."
        raise ConfigurationError(msg) from error
    if not text.strip():
        msg = f"Styleguide file '{path}' is empty."
        raise ConfigurationError(msg)
    truncated = len(text) > max_chars
    return Styleguide(path=path, text=text[:max_chars], truncated=truncated)
