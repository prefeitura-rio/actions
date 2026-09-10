#!/usr/bin/env bash
set -euo pipefail

CHECK=
LANGUAGE=
FRAMEWORK=
ERROR_FILE=
SUCCESS_FILE=
NAME_FILE=
SUMMARY_FILE=

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
    --framework)
      FRAMEWORK=${2-}
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
    --name-file)
      NAME_FILE=${2:?missing value for --name-file}
      shift 2
      ;;
    --summary-file)
      SUMMARY_FILE=${2:?missing value for --summary-file}
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$CHECK" in
  app:format) CHECK_NAME=Format ;;
  app:lint) CHECK_NAME=Lint ;;
  app:strlint) CHECK_NAME='Structural Lint' ;;
  app:typecheck) CHECK_NAME='Type Check' ;;
  app:test) CHECK_NAME=Test ;;
  *) CHECK_NAME=$CHECK ;;
esac

case "$LANGUAGE" in
  go) LANGUAGE_NAME=Go ;;
  python) LANGUAGE_NAME=Python ;;
  typescript)
    case "$FRAMEWORK" in
      vue) LANGUAGE_NAME='Typescript - Vue' ;;
      nuxt) LANGUAGE_NAME='Typescript - Nuxt' ;;
      *) LANGUAGE_NAME=Typescript ;;
    esac
    ;;
  *) LANGUAGE_NAME= ;;
esac

if [[ -n "$LANGUAGE_NAME" && "$CHECK" != detect-only ]]; then
  SUMMARY_NAME="$CHECK_NAME ($LANGUAGE_NAME)"
else
  SUMMARY_NAME=$CHECK_NAME
fi

printf '%s\n' "$SUMMARY_NAME" > "$NAME_FILE"
{
  printf '### Quality Gate: %s\n' "$SUMMARY_NAME"
  if [[ -f "$SUCCESS_FILE" ]]; then
    printf 'Outcome: success\n'
  else
    printf 'Outcome: failure\n'
  fi
  printf 'Error:\n'
  if [[ -s "$ERROR_FILE" ]]; then
    cat "$ERROR_FILE"
  else
    printf 'None\n'
  fi
} > "$SUMMARY_FILE"
