#!/usr/bin/env bash
# Picks the python-version and the cache of the "Setup environment" step.
# The python3 on PATH is kept (empty version, the previous behavior) when it
# can create a virtual environment with pip, which install-tools.sh needs for
# checkov. Otherwise, as on the ARC runner image (python3 without ensurepip,
# i.e. without python3-venv) or with no python3 at all, it asks setup-python
# for $FALLBACK_PYTHON.
# The pip cache of setup-python stays on only when a file of the workspace
# matches its default cache-dependency-path (**/requirements.txt, then
# **/pyproject.toml): with `cache: pip` and no such file, as in a Node
# repository, setup-python fails the step. A symlink counts when it points to
# a file, as in setup-python. Writes version and cache to $GITHUB_OUTPUT.
set -euo pipefail

FALLBACK_PYTHON=3.12

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT

version=""
if ! python3 -m venv "$probe/venv" >/dev/null 2>&1; then
    version="$FALLBACK_PYTHON"
    echo "::notice title=SAST Python::python3 on PATH cannot create a virtual environment (missing, or without ensurepip/python3-venv), so Python $version is set up for the scanner tools"
fi

workspace="${GITHUB_WORKSPACE:-$PWD}"
dependency_file=""
if [[ -d "$workspace" ]]; then
    dependency_file=$(find -L "$workspace" \( -name requirements.txt -o -name pyproject.toml \) -type f -print -quit 2>/dev/null || true)
fi

cache=""
if [[ -n "$dependency_file" ]]; then
    cache="pip"
elif [[ -n "$version" ]]; then
    echo "::notice title=SAST Python cache::no requirements.txt or pyproject.toml in the workspace, so the pip cache of setup-python is off"
fi

{
    echo "version=$version"
    echo "cache=$cache"
} >>"$GITHUB_OUTPUT"
