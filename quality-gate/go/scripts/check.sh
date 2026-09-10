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

install_format_tools() {
  local output="$QUALITY_GATE_TOOL_DOWNLOADS/gofumpt"
  qg_download_verified \
    "https://github.com/mvdan/gofumpt/releases/download/v0.8.0/gofumpt_v0.8.0_linux_amd64" \
    "$output" \
    "11604bbaf7321abcc2fca2c6a37b7e9198bb1e76e5a86f297c07201e8ab1fda9" \
    gofumpt
  install -m 0755 "$output" "$QUALITY_GATE_TOOL_BIN/gofumpt"
  GOBIN="$QUALITY_GATE_TOOL_BIN" go install golang.org/x/tools/cmd/goimports@v0.35.0
}

install_lint_tool() {
  if ! command -v golangci-lint >/dev/null 2>&1; then
    GOBIN="$QUALITY_GATE_TOOL_BIN" go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2
  fi
}

format_gofumpt() {
  local unformatted diff_output
  unformatted=$(gofumpt -l .)
  if [[ -n "$unformatted" ]]; then
    diff_output=$(gofumpt -d . || true)
    printf '%s\n' "$unformatted"
    printf '%s\n' "$diff_output"
    qg_report "$(cat <<EOF
gofumpt found unformatted files.

Files requiring formatting:
$(printf '%s\n' "$unformatted" | while IFS= read -r file; do printf -- '- %s\n' "$file"; done)

Formatting diff:
$(printf '%s\n' "$diff_output" | awk 'NR <= 200 { print } NR == 201 { print "... diff truncated; run the command below for the complete result." }')

Fix locally with: gofumpt -w .
EOF
)"
    return 1
  fi
  echo "gofumpt: all files are correctly formatted."
}

format_goimports() {
  local unformatted diff_output
  unformatted=$(goimports -l .)
  if [[ -n "$unformatted" ]]; then
    diff_output=$(goimports -d . || true)
    printf '%s\n' "$unformatted"
    printf '%s\n' "$diff_output"
    qg_report "$(cat <<EOF
goimports found files with unorganised imports.

Files requiring import organisation:
$(printf '%s\n' "$unformatted" | while IFS= read -r file; do printf -- '- %s\n' "$file"; done)

Formatting diff:
$(printf '%s\n' "$diff_output" | awk 'NR <= 200 { print } NR == 201 { print "... diff truncated; run the command below for the complete result." }')

Fix locally with: goimports -w .
EOF
)"
    return 1
  fi
  echo "goimports: all import blocks are correctly organised."
}

run_strlint() {
  local tmp_config
  tmp_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX.yaml")
  trap 'rm -f "$tmp_config"' RETURN
  printf 'ruleDirs:\n  - %s/rules\n' "$ACTION_DIR" > "$tmp_config"
  ast-grep scan --config "$tmp_config"
  echo "Org-wide ast-grep rules passed."

  if [[ -f sgconfig.yaml || -d rules ]]; then
    ast-grep scan
    echo "Repo-local ast-grep rules passed."
  elif [[ -f .quality-gate/sgconfig.yaml || -d .quality-gate/rules ]]; then
    ast-grep scan --config .quality-gate/sgconfig.yaml
    echo "Repo-local ast-grep rules passed."
  else
    echo "No repo-local sgconfig.yaml or rules/ found - skipping."
  fi

  if [[ -d tests ]]; then
    ast-grep test -t tests
    echo "Repo-local rule tests passed."
  else
    echo "No tests/ directory found - skipping rule tests."
  fi
}

case "$CHECK" in
  app:format)
    install_format_tools
    format_gofumpt
    format_goimports
    ;;
  app:lint)
    install_lint_tool
    if [[ -f .golangci.yml || -f .golangci.yaml ]]; then
      golangci-lint run
    else
      golangci-lint run --config "$ACTION_DIR/.golangci.yml"
    fi
    ;;
  app:strlint)
    qg_install_ast_grep
    run_strlint
    ;;
  app:typecheck)
    go vet ./...
    if [[ -d cmd ]]; then
      go build -ldflags="-s -w" -o /dev/null ./cmd/...
    else
      go build -ldflags="-s -w" -o /dev/null .
    fi
    ;;
  app:test)
    CGO_ENABLED=1 go test -count=1 -race -v ./...
    ;;
  *)
    qg_error "Unknown check: $CHECK"
    exit 2
    ;;
esac
