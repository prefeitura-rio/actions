#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/diagnostics.sh"

CHECK=
LANGUAGE=
WORKING_DIRECTORY=.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=${2:?missing value for --check}
      shift 2
      ;;
    --language)
      LANGUAGE=${2-}
      shift 2
      ;;
    --working-directory)
      WORKING_DIRECTORY=${2:?missing value for --working-directory}
      shift 2
      ;;
    *)
      qg_error "Unknown argument: $1"
      exit 2
      ;;
  esac
done

cd "$WORKING_DIRECTORY"

detected=()
[[ -f go.mod ]] && detected+=(go)
[[ -f pyproject.toml || -f setup.py ]] && detected+=(python)
[[ -f package.json && -f tsconfig.json ]] && detected+=(typescript)

if [[ ${#detected[@]} -eq 0 ]]; then
  qg_error "Could not detect a supported language. Expected go.mod, pyproject.toml, or package.json+tsconfig.json."
  exit 1
fi

if [[ "$CHECK" == detect-only ]]; then
  languages=
  for language in "${detected[@]}"; do
    [[ -n "$languages" ]] && languages+=,
    languages+="\"$language\""
  done
  printf 'languages=[%s]\n' "$languages"
  exit 0
fi

if [[ -n "$LANGUAGE" ]]; then
  found=false
  for detected_language in "${detected[@]}"; do
    [[ "$detected_language" == "$LANGUAGE" ]] && found=true
  done
  if [[ "$found" != true ]]; then
    qg_error "Requested language '${LANGUAGE}' not detected in project. Detected: ${detected[*]:-none}."
    exit 1
  fi
  printf 'name=%s\n' "$LANGUAGE"
  exit 0
fi

if [[ ${#detected[@]} -gt 1 ]]; then
  qg_error "Multiple supported languages detected: ${detected[*]}. Run quality-gate once per language, or use the detect-only check to enumerate languages."
  exit 1
fi

printf 'name=%s\n' "${detected[0]}"
