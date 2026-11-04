from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from quality_gate.ai_review.errors import ConfigurationError
from quality_gate.ai_review.sources import (
    candidate_paths,
    is_reviewable,
    repository_root,
    select_sources,
)
from tests.support import git

if TYPE_CHECKING:
    from pathlib import Path


def _branch_with_changes(repository: Path) -> None:
    _ = git(repository, "checkout", "--quiet", "-b", "feature")
    service = repository / "service"
    _ = (service / "new.py").write_text("print('x')\n", encoding="utf-8")
    _ = (service / "old.py").write_text("VALUE = 2\n", encoding="utf-8")
    _ = (service / "notes.txt").write_text("not code\n", encoding="utf-8")
    modules = service / "node_modules"
    modules.mkdir()
    _ = (modules / "lib.js").write_text("console.log(1)\n", encoding="utf-8")
    other = repository / "other"
    other.mkdir()
    _ = (other / "main.go").write_text("package main\n", encoding="utf-8")
    _ = git(repository, "add", "--force", ".")
    _ = git(repository, "commit", "--quiet", "-m", "feature")


def test_repository_root(repository: Path) -> None:
    assert repository_root(repository / "service").resolve() == repository.resolve()


def test_repository_root_rejects_missing_directory(repository: Path) -> None:
    with pytest.raises(ConfigurationError, match="does not exist"):
        _ = repository_root(repository / "missing")


def test_without_base_lists_every_tracked_source_below_working_directory(
    repository: Path,
) -> None:
    _branch_with_changes(repository)

    assert candidate_paths(repository / "service", "") == ["service/new.py", "service/old.py"]


def test_with_base_lists_only_changed_sources(repository: Path) -> None:
    _branch_with_changes(repository)
    _ = git(repository, "checkout", "--quiet", "main")
    _ = (repository / "service" / "main_only.py").write_text("X = 1\n", encoding="utf-8")
    _ = git(repository, "add", ".")
    _ = git(repository, "commit", "--quiet", "-m", "main moves on")
    _ = git(repository, "checkout", "--quiet", "feature")

    assert candidate_paths(repository, "main") == [
        "other/main.go",
        "service/new.py",
        "service/old.py",
    ]


def test_base_is_also_resolved_on_origin(repository: Path) -> None:
    _ = git(repository, "update-ref", "refs/remotes/origin/develop", "HEAD")
    _branch_with_changes(repository)

    assert candidate_paths(repository / "service", "develop") == [
        "service/new.py",
        "service/old.py",
    ]


def test_unknown_base_is_rejected_with_remediation(repository: Path) -> None:
    with pytest.raises(ConfigurationError) as raised:
        _ = candidate_paths(repository, "missing-branch")

    assert str(raised.value) == (
        "Base reference 'missing-branch' was not found. Fetch it before the review "
        "(for example actions/checkout with fetch-depth: 0)."
    )


def test_option_like_base_is_rejected(repository: Path) -> None:
    with pytest.raises(ConfigurationError, match="Invalid base reference"):
        _ = candidate_paths(repository, "--output=/tmp/x")


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("app/main.py", True),
        ("cmd/server/main.go", True),
        ("web/src/App.vue", True),
        ("web/src/page.TSX", True),
        ("web/node_modules/react/index.js", False),
        ("vendor/github.com/x/y.go", False),
        ("README.md", False),
        ("go.mod", False),
    ],
)
def test_is_reviewable(path: str, *, expected: bool) -> None:
    assert is_reviewable(path) is expected


def test_select_sources_applies_limits(tmp_path: Path) -> None:
    _ = (tmp_path / "a.py").write_text("A = 1\n", encoding="utf-8")
    _ = (tmp_path / "big.py").write_text("B = 1\n" * 100, encoding="utf-8")
    _ = (tmp_path / "binary.py").write_bytes(b"\xff\xfe\x00")
    _ = (tmp_path / "empty.py").write_text("\n", encoding="utf-8")
    _ = (tmp_path / "z.py").write_text("Z = 1\n", encoding="utf-8")

    selection = select_sources(
        tmp_path,
        ["a.py", "big.py", "binary.py", "empty.py", "gone.py", "z.py"],
        max_files=1,
        max_file_bytes=50,
    )

    assert [source.path for source in selection.files] == ["a.py"]
    assert selection.skipped == (
        ("big.py", "over the limit of 1 files"),
        ("binary.py", "over the limit of 1 files"),
        ("empty.py", "over the limit of 1 files"),
        ("gone.py", "over the limit of 1 files"),
        ("z.py", "over the limit of 1 files"),
    )

    selection = select_sources(
        tmp_path,
        ["a.py", "big.py", "binary.py", "empty.py", "gone.py"],
        max_files=10,
        max_file_bytes=50,
    )

    assert [source.path for source in selection.files] == ["a.py"]
    assert selection.skipped == (
        ("big.py", "larger than 50 bytes"),
        ("binary.py", "not UTF-8 text"),
        ("gone.py", "not a regular file"),
    )
