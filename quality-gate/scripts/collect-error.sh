#!/usr/bin/env bash
set -euo pipefail

CHECK=
ERROR_FILE=
SUCCESS_FILE=
MAX_BYTES=65536

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=${2:?missing value for --check}
      shift 2
      ;;
    --error-file)
      ERROR_FILE=${2:?missing value for --error-file}
      shift 2
      ;;
    --success-file)
      SUCCESS_FILE=${2:?missing value for --success-file}
      shift 2
      ;;
    --max-bytes)
      MAX_BYTES=${2:?missing value for --max-bytes}
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -s "$ERROR_FILE" ]]; then
  selected_file=$ERROR_FILE
elif [[ ! -f "$SUCCESS_FILE" ]]; then
  printf "Quality gate '%s' failed. See the failed quality-gate step logs for details.\n" "$CHECK" > "$ERROR_FILE"
  selected_file=$ERROR_FILE
else
  exit 0
fi

size=$(wc -c < "$selected_file")
if (( size <= MAX_BYTES )); then
  cat "$selected_file"
else
  head -c 57344 "$selected_file"
  printf '\n\n... error output truncated; see the quality-gate step logs for the complete report. ...\n\n'
  tail -c 8192 "$selected_file"
fi
