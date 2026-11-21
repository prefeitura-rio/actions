#!/usr/bin/env bash
# Picks the python-version of the "Setup environment" step. The python3 on
# PATH is kept (empty version, the previous behavior) when it can create a
# virtual environment with pip, which install-tools.sh needs for checkov.
# Otherwise, as on the ARC runner image (python3 without ensurepip, i.e.
# without python3-venv) or with no python3 at all, it asks setup-python for
# $FALLBACK_PYTHON. Writes version to $GITHUB_OUTPUT.
set -euo pipefail

FALLBACK_PYTHON=3.12

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT

version=""
if ! python3 -m venv "$probe/venv" >/dev/null 2>&1; then
    version="$FALLBACK_PYTHON"
    echo "::notice title=SAST Python::python3 on PATH cannot create a virtual environment (missing, or without ensurepip/python3-venv), so Python $version is set up for the scanner tools"
fi

echo "version=$version" >>"$GITHUB_OUTPUT"
