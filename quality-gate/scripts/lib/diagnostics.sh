#!/usr/bin/env bash

qg_error() {
  local message=$1

  if [[ -n "${QUALITY_GATE_ERROR_FILE:-}" ]]; then
    printf '%s\n' "$message" > "$QUALITY_GATE_ERROR_FILE"
  fi
  printf '%s\n' "$message" >&2
}

qg_typecheck_output() {
  local tool=$1
  local output=$2
  local diagnostic

  case "$tool" in
    uv)
      diagnostic=$(printf '%s\n' "$output" | awk '
        /^error:/ { started=1 }
        /^hint:/ { exit }
        started { print }
      ')
      diagnostic=$(printf '%s\n' "$diagnostic" | sed -E 's/[[:space:]]+To (create|update|install|run) .*([Rr]un `.*)$//')
      [[ -n "$diagnostic" ]] && printf '%s\n' "$diagnostic" || printf '%s\n' "$output"
      ;;
    project-info)
      printf '%s\n' "$output" | sed -E 's/\.[[:space:]]+(Add|Commit|Update|Run) .*/./'
      ;;
    *)
      printf '%s\n' "$output"
      ;;
  esac
}

qg_typecheck_hint() {
  local tool=$1
  local output=$2
  local hint

  hint=$(printf '%s\n' "$output" | awk '
    /^hint:/ { started=1 }
    started { print }
  ')
  if [[ -n "$hint" ]]; then
    printf '%s\n' "$hint"
    return
  fi

  if [[ "$tool" == uv ]]; then
    printf '%s\n' "$output" | sed -nE 's/^.*([Rr]un `.*)$/\1/p'
  elif [[ "$tool" == project-info ]]; then
    printf '%s\n' "$output" | sed -nE 's/^.*\. (Add|Commit|Update|Run) (.*)$/\1 \2/p'
  fi
}

qg_typecheck_limit() {
  local output=$1

  printf '%s\n' "$output" | awk '
    NR <= 200 { print }
    NR == 201 { print "... diagnostics truncated; see the job logs for the complete output." }
  '
}

qg_typecheck_error() {
  local tool=$1
  local output=$2
  local diagnostic hint message

  diagnostic=$(qg_typecheck_output "$tool" "$output")
  hint=$(qg_typecheck_hint "$tool" "$output")
  diagnostic=$(qg_typecheck_limit "$diagnostic")

  message=$(cat <<EOF
Error:
\`\`\`text
$diagnostic
\`\`\`
EOF
)
  if [[ -n "$hint" ]]; then
    message+=$(cat <<EOF

How to fix it:
\`\`\`text
$hint
\`\`\`
EOF
)
  fi
  qg_error "$message"
}

qg_run_typecheck() {
  local tool=$1
  shift
  local output status

  if output=$("$@" 2>&1); then
    [[ -z "$output" ]] || printf '%s\n' "$output"
    return 0
  else
    status=$?
  fi

  qg_typecheck_error "$tool" "$output"
  return "$status"
}
