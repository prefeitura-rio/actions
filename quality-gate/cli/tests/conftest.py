from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from tests.support import git

if TYPE_CHECKING:
    from pathlib import Path


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    """Git repository with a styleguide and one committed Python file on ``main``."""
    root = tmp_path / "repo"
    root.mkdir()
    _ = git(root, "init", "--quiet", "--initial-branch=main")
    _ = git(root, "config", "user.email", "qa@example.invalid")
    _ = git(root, "config", "user.name", "Quality Gate Tests")
    _ = (root / "STYLEGUIDE.md").write_text("# Rules\n\n- Never use print.\n", encoding="utf-8")
    service = root / "service"
    service.mkdir()
    _ = (service / "old.py").write_text("VALUE = 1\n", encoding="utf-8")
    _ = git(root, "add", ".")
    _ = git(root, "commit", "--quiet", "-m", "initial")
    return root
