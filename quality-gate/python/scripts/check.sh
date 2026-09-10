#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
QUALITY_GATE_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
source "$QUALITY_GATE_ROOT/scripts/lib/diagnostics.sh"
# shellcheck disable=SC1091
source "$QUALITY_GATE_ROOT/scripts/lib/tools.sh"

CHECK=
PROJECT_DIR=.
ACTION_DIR="$SCRIPT_DIR/.."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=${2:?missing value for --check}
      shift 2
      ;;
    --working-directory)
      PROJECT_DIR=${2:?missing value for --working-directory}
      shift 2
      ;;
    --action-directory)
      ACTION_DIR=${2:?missing value for --action-directory}
      shift 2
      ;;
    *)
      qg_error "Unknown argument: $1"
      exit 2
      ;;
  esac
done

PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd)
ACTION_DIR=$(cd -- "$ACTION_DIR" && pwd)
qg_tool_cache_init
cd "$PROJECT_DIR"

sync_project() {
  if [[ -f pyproject.toml ]]; then
    uv sync --frozen --all-groups
  else
    echo "No pyproject.toml found - skipping uv sync"
  fi
}

format_python() {
  local check_output files diff_output
  if check_output=$(uvx ruff@0.16.4 format --check . 2>&1); then
    echo "ruff format: all files are correctly formatted."
    return 0
  fi

  files=$(printf '%s\n' "$check_output" | awk '
    /^Would reformat: / { sub(/^Would reformat: /, ""); print }
    /^  --> / { file = $2; sub(/:.*/, "", file); print file }
  ' | sort -u)
  if [[ -z "$files" ]]; then
    printf '%s\n' "$check_output"
    qg_error "$(cat <<EOF
ruff format could not complete the formatting check.

Formatter output:
$check_output

Fix locally with: uvx ruff@0.16.4 format .
EOF
)"
    return 1
  fi

  diff_output=$(uvx ruff@0.16.4 format --diff . 2>&1 || true)
  printf '%s\n' "$check_output"
  printf '%s\n' "$diff_output"
  qg_error "$(cat <<EOF
ruff format found formatting differences.

Files requiring formatting:
$(printf '%s\n' "$files" | while IFS= read -r file; do printf -- '- %s\n' "$file"; done)

Formatting diff:
$(printf '%s\n' "$diff_output" | awk 'NR <= 200 { print } NR == 201 { print "... diff truncated; run the command below for the complete result." }')

Fix locally with: uvx ruff@0.16.4 format .
EOF
)"
  return 1
}

run_strlint() {
  local org_config
  org_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX.yaml")
  trap 'rm -f "$org_config"' EXIT
  printf 'ruleDirs:\n  - %s/rules\n' "$ACTION_DIR" > "$org_config"
  ast-grep scan --config "$org_config"
  rm -f "$org_config"
  trap - EXIT
  echo "Org-wide Python ast-grep rules passed."

  if [[ -f sgconfig.yaml || -d rules ]]; then
    ast-grep scan
    echo "Repo-local Python ast-grep rules passed."
  elif [[ -f .quality-gate/sgconfig.yaml || -d .quality-gate/rules ]]; then
    ast-grep scan --config .quality-gate/sgconfig.yaml
    echo "Repo-local Python ast-grep rules passed."
  else
    echo "No repo-local sgconfig.yaml or rules/ found - skipping."
  fi
}

case "$CHECK" in
  app:format)
    sync_project
    format_python
    ;;
  app:lint)
    sync_project
    if [[ -f ruff.toml || -f .ruff.toml ]]; then
      uv run ruff check .
    elif [[ -f pyproject.toml ]] && grep -q '^\[tool\.ruff' pyproject.toml; then
      uv run ruff check .
    else
      uv run ruff check --config "$ACTION_DIR/ruff.toml" .
    fi
    echo "ruff check: no issues found."
    uvx complexipy@7.0.1 .
    echo "complexipy: no complexity issues found."
    ;;
  app:strlint)
    qg_install_ast_grep
    run_strlint
    ;;
  app:typecheck)
    if [[ -f ty.toml ]] || { [[ -f pyproject.toml ]] && grep -q '^\[tool\.ty' pyproject.toml; }; then
      uvx ty@0.0.74 check .
    else
      uvx ty@0.0.74 check --config-file "$ACTION_DIR/ty.toml" .
    fi
    echo "ty: no type errors found."
    ;;
  app:test)
    sync_project
    uv run pytest --cov=src --cov-report=term-missing
    ;;
  *)
    qg_error "Unknown check: $CHECK"
    exit 2
    ;;
esac
