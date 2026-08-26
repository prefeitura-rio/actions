#!/usr/bin/env python3
"""Patches a confirmed upstream checkov bug in
checkov/terraform/module_loading/module_finder.py, present in the pinned
checkov_version and still on the bridgecrewio/checkov `main` branch as of
2026-08.

find_modules() builds excluded_paths_regex as:
    re.compile('|'.join(f"({excluded_paths})"))
`excluded_paths` is a list[str], so the f-string formats the *list itself*
(its repr, e.g. "(['vendor', 'node_modules'])"), and '|'.join() then inserts
'|' between every individual *character* of that string instead of between
each pattern. The result is a garbled regex: with a single simple entry it
merely over-matches (each character becomes its own alternative, so the
"exclusion" matches almost any path), and with two or more entries -- or any
entry containing a regex metacharacter such as brackets or a bare '*' -- it
frequently fails to compile at all (e.g. `re.error: nothing to repeat`),
crashing checkov's terraform runner outright. Reproduced locally against the
pinned checkov version with both single- and multi-pattern --skip-path lists.

This action derives --skip-path from .semgrepignore/sonar-project.properties
(see the "Normalize ignore files" and "Run checkov" steps), which routinely
produces multi-entry, wildcard-bearing lists, so the unpatched bug would make
--skip-path unusable. The patch is verified against the installed source
before applying, so a checkov_version bump either keeps applying cleanly or
fails loudly here instead of silently leaving the bug (and an unreliable
--skip-path) in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

BUGGY = """excluded_paths_regex = re.compile('|'.join(f"({excluded_paths})")) if excluded_paths else None"""
FIXED = """excluded_paths_regex = re.compile('|'.join(f"({p})" for p in excluded_paths)) if excluded_paths else None"""


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: fix_checkov_module_finder.py <path-to-module_finder.py>",
            file=sys.stderr,
        )
        return 1

    target = Path(sys.argv[1])
    if not target.is_file():
        print(
            f"::error title=SAST::checkov module_finder.py not found at {target}",
            file=sys.stderr,
        )
        return 1

    src = target.read_text()
    if FIXED in src:
        print(f"checkov excluded_paths_regex fix already applied to {target}")
        return 0
    if BUGGY not in src:
        print(
            f"::error title=SAST::checkov module_finder.py at {target} matches neither the known-buggy "
            "nor the patched excluded_paths_regex line; --skip-path safety can't be verified for this "
            "checkov_version. Update sast/patches/fix_checkov_module_finder.py.",
            file=sys.stderr,
        )
        return 1

    target.write_text(src.replace(BUGGY, FIXED, 1))
    print(f"patched checkov excluded_paths_regex bug in {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
