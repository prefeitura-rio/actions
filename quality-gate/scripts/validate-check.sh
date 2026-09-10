#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/diagnostics.sh"

VALID="app:format app:lint app:strlint app:typecheck app:test detect-only"
CHECK=${1:-}

valid=false
for value in $VALID; do
  [[ "$value" == "$CHECK" ]] && valid=true
done

if [[ "$valid" != true ]]; then
  qg_error "Invalid check '${CHECK}'. Valid values: ${VALID}"
  exit 1
fi
