#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/diagnostics.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/tools.sh"

qg_tool_cache_init
qg_install_ast_grep
printf '%s\n' "$QUALITY_GATE_TOOL_BIN/ast-grep"
