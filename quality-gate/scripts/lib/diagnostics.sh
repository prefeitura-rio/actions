#!/usr/bin/env bash

qg_error() {
  local message=$1

  if [[ -n "${QUALITY_GATE_ERROR_FILE:-}" ]]; then
    printf '%s\n' "$message" > "$QUALITY_GATE_ERROR_FILE"
  fi
  printf '%s\n' "$message" >&2
}
