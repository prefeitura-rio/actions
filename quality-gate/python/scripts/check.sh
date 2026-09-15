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
    uv sync --frozen --all-groups
  else
    echo "No pyproject.toml found - skipping uv sync"
  fi
}

has_coverage_threshold_override() {
  if [[ -f pyproject.toml ]] && awk '
    /^[[:space:]]*\[tool\.coverage\.report\][[:space:]]*$/ { in_report=1; next }
    /^[[:space:]]*\[/ { in_report=0 }
    in_report && /^[[:space:]]*fail_under[[:space:]]*=/ { found=1 }
    END { exit !found }
  ' pyproject.toml; then
    return 0
  fi

  if [[ -f .coveragerc ]] && awk '
    /^[[:space:]]*\[report\][[:space:]]*$/ { in_report=1; next }
    /^[[:space:]]*\[/ { in_report=0 }
    in_report && /^[[:space:]]*fail_under[[:space:]]*=/ { found=1 }
    END { exit !found }
  ' .coveragerc; then
    return 0
  fi

  return 1
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

  local diff_status=0
  diff_output=$(uvx ruff@0.16.4 format --diff . 2>&1) || diff_status=$?
  if [[ "$diff_status" -ne 0 && "$diff_status" -ne 1 ]] || [[ -z "$diff_output" ]]; then
    printf '%s\n' "$diff_output"
    qg_error "$(cat <<EOF
ruff format could not complete the formatting check.

Formatter output:
$diff_output

Fix locally with: uvx ruff@0.16.4 format .
EOF
)"
    return 1
  fi
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
    sync_project
    if [[ -f pyrightconfig.json ]] || {
      [[ -f pyproject.toml ]] && grep -qE '^\[tool\.(basedpyright|pyright)' pyproject.toml
    }; then
      uvx "basedpyright@${BASEDPYRIGHT_VERSION}" --project "$PROJECT_DIR"
    else
      uvx "basedpyright@${BASEDPYRIGHT_VERSION}" \
        --project "$ACTION_DIR/pyrightconfig.json" .
    fi
    echo "basedpyright: no type errors found."
    ;;
  app:test)
    sync_project
    pytest_args=(--cov-report=term-missing)
    if [[ -d src ]]; then
      pytest_args+=(--cov=src)
    else
      pytest_args+=(--cov)
    fi
    if ! has_coverage_threshold_override; then
      pytest_args+=(--cov-fail-under="$DEFAULT_COVERAGE_THRESHOLD")
    fi
    uv run pytest "${pytest_args[@]}"
    ;;
  *)
    qg_error "Unknown check: $CHECK"
    exit 2
    ;;
esac
