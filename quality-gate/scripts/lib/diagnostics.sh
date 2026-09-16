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

  case "$tool" in
    uv)
      local diagnostic
      diagnostic=$(printf '%s\n' "$output" | awk '
        /^error:/ { started=1 }
        started { print }
      ')
      [[ -n "$diagnostic" ]] && printf '%s\n' "$diagnostic" || printf '%s\n' "$output"
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
  local command=$2
  local output=$3
  local expected=${4:-"$command must exit successfully (exit 0)."}
  local fix=${5:-}
  local diagnostic hint message

  diagnostic=$(qg_typecheck_output "$tool" "$output")
  diagnostic=$(qg_typecheck_limit "$diagnostic")
  hint=$(qg_typecheck_hint "$tool" "$diagnostic")
  if [[ -z "$fix" ]]; then
    if [[ -n "$hint" ]]; then
      fix="$hint"
    else
      fix=$(cat <<EOF
Run the command locally and resolve the diagnostics shown above:
$command
EOF
)
    fi
  fi

  message=$(cat <<EOF
#### Error

Error:
\`\`\`text
$diagnostic
\`\`\`

What was expected:
\`\`\`text
$expected
\`\`\`

How to fix it:
\`\`\`text
$fix
\`\`\`
EOF
)
  qg_error "$message"
}

qg_run_typecheck() {
  local tool=$1
  local command=$2
  shift 2
  local output status

  if output=$("$@" 2>&1); then
    [[ -z "$output" ]] || printf '%s\n' "$output"
    return 0
  else
    status=$?
  fi

  qg_typecheck_error "$tool" "$command" "$output"
  return "$status"
}
