from __future__ import annotations

from pathlib import Path

import pytest

from quality_gate.ai_review.errors import ConfigurationError
from quality_gate.ai_review.styleguide import find_styleguide, load_styleguide


def test_finds_styleguide_at_repository_root(repository: Path) -> None:
    found = find_styleguide(repository / "service", repository, None)

    assert found == repository / "STYLEGUIDE.md"


def test_project_styleguide_wins_over_repository_root(repository: Path) -> None:
    docs = repository / "service" / "docs"
    docs.mkdir()
    _ = (docs / "Style-Guide.md").write_text("- Project rule.\n", encoding="utf-8")

    found = find_styleguide(repository / "service", repository, None)

    assert found == docs / "Style-Guide.md"


def test_finds_styleguide_in_github_directory(tmp_path: Path) -> None:
    github = tmp_path / ".github"
    github.mkdir()
    _ = (github / "styleguide.md").write_text("- Rule.\n", encoding="utf-8")

    assert find_styleguide(tmp_path, tmp_path, None) == github / "styleguide.md"


def test_explicit_styleguide_is_relative_to_working_directory(repository: Path) -> None:
    rules = repository / "service" / "RULES.md"
    _ = rules.write_text("- Rule.\n", encoding="utf-8")

    found = find_styleguide(repository / "service", repository, rules.relative_to(rules.parent))

    assert found == rules


def test_missing_explicit_styleguide_is_rejected(repository: Path) -> None:
    with pytest.raises(ConfigurationError) as raised:
        _ = find_styleguide(repository, repository, Path("nope.md"))

    assert str(raised.value) == "Styleguide file 'nope.md' does not exist."


def test_no_styleguide_is_rejected_with_remediation(tmp_path: Path) -> None:
    with pytest.raises(ConfigurationError) as raised:
        _ = find_styleguide(tmp_path, tmp_path, None)

    assert str(raised.value) == (
        "No styleguide found. Add STYLEGUIDE.md to the project or repository root "
        "(or to docs/ or .github/), or set the styleguide input."
    )


def test_styleguide_is_truncated(tmp_path: Path) -> None:
    path = tmp_path / "STYLEGUIDE.md"
    _ = path.write_text("abcdef", encoding="utf-8")

    styleguide = load_styleguide(path, 4)

    assert styleguide.text == "abcd"
    assert styleguide.truncated


def test_empty_styleguide_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "STYLEGUIDE.md"
    _ = path.write_text("  \n", encoding="utf-8")

    with pytest.raises(ConfigurationError, match="is empty"):
        _ = load_styleguide(path, 100)


def test_binary_styleguide_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "STYLEGUIDE.md"
    _ = path.write_bytes(b"\xff\xfe\x00rules")

    with pytest.raises(ConfigurationError, match="not valid UTF-8"):
        _ = load_styleguide(path, 100)
