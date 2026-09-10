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

GOLANGCI_LINT_VERSION="2.12.2"

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
  local target="$QUALITY_GATE_TOOL_BIN/golangci-lint"
  local is_valid=false

  if [[ -x "$target" ]]; then
    local version_output
    version_output=$("$target" version 2>&1 || true)
    if [[ "$version_output" == *"$GOLANGCI_LINT_VERSION"* ]]; then
      is_valid=true
    fi
  fi

  if [[ "$is_valid" != true ]]; then
    GOBIN="$QUALITY_GATE_TOOL_BIN" go install "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v$GOLANGCI_LINT_VERSION"
  fi
}

format_gofumpt() {
  local unformatted diff_output
  unformatted=$(gofumpt -l .)
  if [[ -n "$unformatted" ]]; then
    if ! diff_output=$(gofumpt -d . 2>&1); then
      qg_error "$(cat <<EOF
gofumpt could not complete the formatting check.

Formatter output:
$diff_output

Fix locally with: gofumpt -w .
EOF
)"
      return 1
    fi
    printf '%s\n' "$unformatted"
    printf '%s\n' "$diff_output"
    qg_error "$(cat <<EOF
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
    if ! diff_output=$(goimports -d . 2>&1); then
      qg_error "$(cat <<EOF
goimports could not complete the import organisation check.

Formatter output:
$diff_output

Fix locally with: goimports -w .
EOF
)"
      return 1
    fi
    printf '%s\n' "$unformatted"
    printf '%s\n' "$diff_output"
    qg_error "$(cat <<EOF
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
  local cleanup
  printf -v cleanup 'rm -f -- %q' "$tmp_config"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  printf 'ruleDirs:\n  - %s/rules\n' "$ACTION_DIR" > "$tmp_config"
  ast-grep scan --config "$tmp_config"
  rm -f "$tmp_config"
  trap - EXIT
  echo "Org-wide ast-grep rules passed."

  if [[ -f sgconfig.yaml || -d rules ]]; then
    ast-grep scan
    echo "Repo-local ast-grep rules passed."
  elif [[ -f .quality-gate/sgconfig.yaml ]]; then
    ast-grep scan --config .quality-gate/sgconfig.yaml
    echo "Repo-local ast-grep rules passed."
  elif [[ -d .quality-gate/rules ]]; then
    local repo_config
    repo_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate-local.XXXXXX.yaml")
    printf 'ruleDirs:\n  - .quality-gate/rules\n' > "$repo_config"
    ast-grep scan --config "$repo_config"
    rm -f "$repo_config"
    echo "Repo-local ast-grep rules passed."
  else
    echo "No repo-local sgconfig.yaml or rules/ found - skipping."
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
      go build -ldflags="-s -w" -o /dev/null ./...
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
