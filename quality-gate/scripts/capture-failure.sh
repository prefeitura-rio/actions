#!/usr/bin/env bash

quality_gate_capture_failure() {
  local status=$?

  if [[ "$status" -ne 0 && ! -s "$QUALITY_GATE_ERROR_FILE" ]]; then
    if [[ "${QUALITY_GATE_CHECK:-}" == app:typecheck ]]; then
      printf 'Command failed (exit %s): %s\n' "$status" "$BASH_COMMAND" > "$QUALITY_GATE_ERROR_FILE"
    else
      sleep 0.1
      {
        printf 'Command failed (exit %s): %s\n\nRecent output:\n' "$status" "$BASH_COMMAND"
        sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' "$QUALITY_GATE_OUTPUT_LOG" | tail -n 80 || true
      } > "$QUALITY_GATE_ERROR_FILE"
    fi
  fi
  exit "$status"
}

if [[ "${QUALITY_GATE_CAPTURE_ACTIVE:-}" != 1 ]]; then
  export QUALITY_GATE_CAPTURE_ACTIVE=1
  exec > >(tee -a "$QUALITY_GATE_OUTPUT_LOG") 2>&1
  trap quality_gate_capture_failure ERR
fi
