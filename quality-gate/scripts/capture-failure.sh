#!/usr/bin/env bash

quality_gate_capture_failure() {
  local status=$?

  if [[ "$status" -ne 0 && ! -s "$QUALITY_GATE_ERROR_FILE" ]]; then
    sleep 0.05
    {
      printf 'Command failed (exit %s): %s\n\nRecent output:\n' "$status" "$BASH_COMMAND"
      sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$QUALITY_GATE_OUTPUT_LOG" | tail -n 80 || true
    } > "$QUALITY_GATE_ERROR_FILE"
  fi
  exit "$status"
}

exec > >(tee -a "$QUALITY_GATE_OUTPUT_LOG") 2>&1
trap quality_gate_capture_failure ERR
