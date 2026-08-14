#!/usr/bin/env bash
set -euo pipefail

# CHECKOV_VERSION is supplied by the step's env: block (from inputs.checkov_version).
COSIGN_VERSION=3.1.1
OPENGREP_VERSION=1.23.0
SYFT_VERSION=1.46.0
GRYPE_VERSION=0.115.0
TOOL_DIR="$HOME/.sast-tools"
PY_VERSION=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')

mkdir -p "$TOOL_DIR/bin" "$TOOL_DIR/dl"
echo "$TOOL_DIR/bin" >> "$GITHUB_PATH"

{
  echo "TOOL_DIR=$TOOL_DIR"
  echo "TOOL_BIN=$TOOL_DIR/bin"
  echo "TOOL_DL=$TOOL_DIR/dl"
  echo "COSIGN_VERSION=$COSIGN_VERSION"
  echo "OPENGREP_VERSION=$OPENGREP_VERSION"
  echo "SYFT_VERSION=$SYFT_VERSION"
  echo "GRYPE_VERSION=$GRYPE_VERSION"
  echo "CHECKOV_VERSION=$CHECKOV_VERSION"
} >> "$GITHUB_ENV"

echo "dir=$TOOL_DIR" >> "$GITHUB_OUTPUT"
echo "key=sast-tools-$(uname -s)-$(uname -m)-cosign${COSIGN_VERSION}-opengrep${OPENGREP_VERSION}-syft${SYFT_VERSION}-grype${GRYPE_VERSION}-checkov${CHECKOV_VERSION}-py${PY_VERSION}" >> "$GITHUB_OUTPUT"
