#!/usr/bin/env bash

QUALITY_GATE_FLUSH_ATTEMPTS=50

quality_gate_flush_output() {
  local pid=${QUALITY_GATE_TEE_PID:-}
  local attempt

  if [[ -z "$pid" || "$BASHPID" != "${QUALITY_GATE_SHELL_PID:-}" ]]; then
    return 1
  fi
  QUALITY_GATE_TEE_PID=
  exec 1>&"$QUALITY_GATE_STDOUT_FD" 2>&"$QUALITY_GATE_STDERR_FD"
  for ((attempt = 0; attempt < QUALITY_GATE_FLUSH_ATTEMPTS; attempt++)); do
    kill -0 "$pid" 2> /dev/null || return 0
    sleep 0.1
  done
  return 0
}

quality_gate_capture_failure() {
  local status=$?

  if [[ "$status" -ne 0 && ! -s "$QUALITY_GATE_ERROR_FILE" ]]; then
    if [[ "${QUALITY_GATE_CHECK:-}" == app:typecheck || "${QUALITY_GATE_CHECK:-}" == app:format || "${QUALITY_GATE_CHECK:-}" == app:lint ]]; then
      printf 'Command failed (exit %s): %s\n' "$status" "$BASH_COMMAND" > "$QUALITY_GATE_ERROR_FILE"
    else
      quality_gate_flush_output || sleep 0.1
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
  if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    exec {QUALITY_GATE_STDOUT_FD}>&1 {QUALITY_GATE_STDERR_FD}>&2
    exec > >(tee -a "$QUALITY_GATE_OUTPUT_LOG") 2>&1
    QUALITY_GATE_TEE_PID=$!
    QUALITY_GATE_SHELL_PID=$BASHPID
    trap 'quality_gate_flush_output || true' EXIT
  else
    exec > >(tee -a "$QUALITY_GATE_OUTPUT_LOG") 2>&1
  fi
  trap quality_gate_capture_failure ERR
fi
