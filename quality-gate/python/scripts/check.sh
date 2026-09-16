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
BASEDPYRIGHT_VERSION="1.39.10"
DEFAULT_COVERAGE_THRESHOLD="80"

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
    if [[ "$CHECK" == app:typecheck || "$CHECK" == app:format || "$CHECK" == app:lint ]]; then
      qg_run_tool \
        uv \
        uv sync --frozen --all-groups
    else
      uv sync --frozen --all-groups
    fi
  else
    echo "No pyproject.toml found - skipping uv sync"
  fi
}

_resolve_coverage_config() {
  _COVERAGE_CONFIG_FILE="${COVERAGE_RCFILE:-}"
  _COVERAGE_CONFIG_FORMAT=ini

  if [[ -z "$_COVERAGE_CONFIG_FILE" ]]; then
    if [[ -f .coveragerc ]]; then
      _COVERAGE_CONFIG_FILE=.coveragerc
    elif [[ -f .coveragerc.toml ]]; then
      _COVERAGE_CONFIG_FILE=.coveragerc.toml
      _COVERAGE_CONFIG_FORMAT=toml
    elif [[ -f setup.cfg ]] && grep -qE '^[[:space:]]*\[coverage:' setup.cfg; then
      _COVERAGE_CONFIG_FILE=setup.cfg
    elif [[ -f tox.ini ]] && grep -qE '^[[:space:]]*\[coverage:' tox.ini; then
      _COVERAGE_CONFIG_FILE=tox.ini
    elif [[ -f pyproject.toml ]]; then
      _COVERAGE_CONFIG_FILE=pyproject.toml
      _COVERAGE_CONFIG_FORMAT=toml
    fi
  elif [[ "$_COVERAGE_CONFIG_FILE" == *.toml ]]; then
    _COVERAGE_CONFIG_FORMAT=toml
  fi
}

has_coverage_threshold_override() {
  _resolve_coverage_config
  [[ -n "$_COVERAGE_CONFIG_FILE" && -f "$_COVERAGE_CONFIG_FILE" ]] || return 1

  if [[ "$_COVERAGE_CONFIG_FORMAT" == toml ]]; then
    # coverage.py uses the tool.coverage namespace for every TOML config file.
    awk '
      /^[[:space:]]*\[tool\.coverage\.report\]([[:space:]]*#.*)?$/ { in_report=1; next }
      /^[[:space:]]*\[/ { in_report=0 }
      in_report && /^[[:space:]]*fail_under[[:space:]]*=/ { found=1 }
      END { exit !found }
    ' "$_COVERAGE_CONFIG_FILE"
  else
    awk '
      /^[[:space:]]*\[(report|coverage:report)\]([[:space:]]*[#;].*)?$/ { in_report=1; next }
      /^[[:space:]]*\[/ { in_report=0 }
      in_report && /^[[:space:]]*fail_under[[:space:]]*=/ { found=1 }
      END { exit !found }
    ' "$_COVERAGE_CONFIG_FILE"
  fi
}

get_coverage_fail_under_value() {
  _resolve_coverage_config
  [[ -n "$_COVERAGE_CONFIG_FILE" && -f "$_COVERAGE_CONFIG_FILE" ]] || return 0

  if [[ "$_COVERAGE_CONFIG_FORMAT" == toml ]]; then
    awk '
      /^[[:space:]]*\[tool\.coverage\.report\]([[:space:]]*#.*)?$/ { in_report=1; next }
      /^[[:space:]]*\[/ { in_report=0 }
      in_report && /^[[:space:]]*fail_under[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]].*$/, ""); print; exit
      }
    ' "$_COVERAGE_CONFIG_FILE"
  else
    awk '
      /^[[:space:]]*\[(report|coverage:report)\]([[:space:]]*[#;].*)?$/ { in_report=1; next }
      /^[[:space:]]*\[/ { in_report=0 }
      in_report && /^[[:space:]]*fail_under[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]].*$/, ""); print; exit
      }
    ' "$_COVERAGE_CONFIG_FILE"
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
    qg_format_error \
      "ruff format could not complete the formatting check." \
      "uvx ruff@0.16.4 format ." \
      "$check_output"
    return 1
  fi

  local diff_status=0
  diff_output=$(uvx ruff@0.16.4 format --diff . 2>&1) || diff_status=$?
  if [[ "$diff_status" -ne 0 && "$diff_status" -ne 1 ]] || [[ -z "$diff_output" ]]; then
    printf '%s\n' "$diff_output"
    qg_format_error \
      "ruff format could not complete the formatting check." \
      "uvx ruff@0.16.4 format ." \
      "$diff_output"
    return 1
  fi
  printf '%s\n' "$check_output"
  printf '%s\n' "$diff_output"
  qg_format_error "$(cat <<EOF
ruff format found formatting differences.

Files requiring formatting:
$(printf '%s\n' "$files" | while IFS= read -r file; do printf -- '- %s\n' "$file"; done)
EOF
)" "uvx ruff@0.16.4 format ."
  return 1
}

run_strlint() {
  local org_config
  org_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX.yaml")
  local cleanup
  printf -v cleanup 'rm -f -- %q' "$org_config"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  printf 'ruleDirs:\n  - %s/rules\n' "$ACTION_DIR" > "$org_config"
  ast-grep scan --config "$org_config"
  rm -f "$org_config"
  trap - EXIT
  echo "Org-wide Python ast-grep rules passed."

  if [[ -f sgconfig.yaml || -d rules ]]; then
    ast-grep scan
    echo "Repo-local Python ast-grep rules passed."
  elif [[ -f .quality-gate/sgconfig.yaml ]]; then
    ast-grep scan --config .quality-gate/sgconfig.yaml
    echo "Repo-local Python ast-grep rules passed."
  elif [[ -d .quality-gate/rules ]]; then
    local repo_config
    repo_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate-local.XXXXXX.yaml")
    printf 'ruleDirs:\n  - .quality-gate/rules\n' > "$repo_config"
    ast-grep scan --config "$repo_config"
    rm -f "$repo_config"
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
    if [[ ! -f pyproject.toml ]]; then
      qg_error "app:lint requires a pyproject.toml with uv configuration. setup.py-only projects are not supported for this check."
      exit 1
    fi
    sync_project
    lint_args=(uvx ruff@0.16.4 check)
    if [[ -f ruff.toml || -f .ruff.toml ]]; then
      lint_args+=(.)
    elif grep -q '^\[tool\.ruff' pyproject.toml; then
      lint_args+=(.)
    else
      lint_args+=(--config "$ACTION_DIR/ruff.toml" .)
    fi
    qg_run_tool ruff "${lint_args[@]}"
    echo "ruff check: no issues found."
    qg_run_tool complexipy uvx complexipy@7.0.1 .
    echo "complexipy: no complexity issues found."
    ;;
  app:strlint)
    qg_install_ast_grep
    run_strlint
    ;;
  app:typecheck)
    if [[ ! -f pyproject.toml ]]; then
      qg_typecheck_error \
        quality-gate \
        'app:typecheck requires a pyproject.toml with uv configuration. setup.py-only projects are not supported for this check.'
      exit 1
    fi
    sync_project
    if [[ -f pyrightconfig.json ]] || {
      [[ -f pyproject.toml ]] && grep -qE '^\[tool\.(basedpyright|pyright)' pyproject.toml
    }; then
      qg_run_typecheck \
        basedpyright \
        uvx "basedpyright@${BASEDPYRIGHT_VERSION}" --project "$PROJECT_DIR"
    else
      qg_run_typecheck \
        basedpyright \
        uvx "basedpyright@${BASEDPYRIGHT_VERSION}" \
          --project "$ACTION_DIR/pyrightconfig.json" .
    fi
    echo "basedpyright: no type errors found."
    ;;
  app:test)
    if [[ ! -f pyproject.toml ]]; then
      qg_error "app:test requires a pyproject.toml with uv configuration. setup.py-only projects are not supported for this check."
      exit 1
    fi
    sync_project
    pytest_args=(--cov-report=term-missing)
    if [[ -d src ]]; then
      pytest_args+=(--cov=src)
    else
      pytest_args+=(--cov)
    fi
    if ! has_coverage_threshold_override; then
      pytest_args+=(--cov-fail-under="$DEFAULT_COVERAGE_THRESHOLD")
    else
      fail_under_value=$(get_coverage_fail_under_value)
      if [[ "$fail_under_value" == "0" ]]; then
        echo "Warning: fail_under = 0 detected in project coverage config. Coverage enforcement is effectively disabled for this project."
      fi
    fi
    uv run pytest "${pytest_args[@]}"
    ;;
  *)
    qg_error "Unknown check: $CHECK"
    exit 2
    ;;
esac
