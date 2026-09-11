#!/usr/bin/env bash

qg_tool_cache_init() {
  QUALITY_GATE_TOOL_CACHE=${QUALITY_GATE_TOOL_CACHE:-"$HOME/.quality-gate-tools"}
  export QUALITY_GATE_TOOL_CACHE
  QUALITY_GATE_TOOL_BIN="$QUALITY_GATE_TOOL_CACHE/bin"
  QUALITY_GATE_TOOL_DOWNLOADS="$QUALITY_GATE_TOOL_CACHE/dl"
  export QUALITY_GATE_TOOL_BIN QUALITY_GATE_TOOL_DOWNLOADS
  mkdir -p "$QUALITY_GATE_TOOL_BIN" "$QUALITY_GATE_TOOL_DOWNLOADS"
  PATH="$QUALITY_GATE_TOOL_BIN:$PATH"
  export PATH
}

qg_download_verified() {
  local url=$1
  local destination=$2
  local checksum=$3
  local name=$4

  if [[ ! -f "$destination" ]] || ! printf '%s  %s\n' "$checksum" "$destination" | sha256sum -c --status; then
    curl -fsSL "$url" -o "$destination"
  fi

  if ! printf '%s  %s\n' "$checksum" "$destination" | sha256sum -c --status; then
    qg_error "sha256 mismatch for $name"
    rm -f "$destination"
    return 1
  fi
}

qg_install_ast_grep() {
  local target="$QUALITY_GATE_TOOL_BIN/ast-grep"
  local expected_version="0.45.1"

  if [[ -x "$target" ]]; then
    local version_output
    version_output=$("$target" --version 2>&1 || true)
    if [[ "$version_output" == *"$expected_version"* ]]; then
      return 0
    fi
  fi

  local output="$QUALITY_GATE_TOOL_DOWNLOADS/sg.zip"

  qg_download_verified \
    "https://github.com/ast-grep/ast-grep/releases/download/${expected_version}/app-x86_64-unknown-linux-gnu.zip" \
    "$output" \
    "76fb6555be6734fb5057dba8d2fb756430f374bb9e1af694cf1ce00e13238d63" \
    ast-grep
  unzip -p "$output" ast-grep > "$target"
  chmod +x "$target"
}
