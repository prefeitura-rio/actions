#!/usr/bin/env bash
set -euo pipefail

CHECK=
LANGUAGE=
FRAMEWORK=
LANGUAGES=
ERROR_FILE=
SUCCESS_FILE=
NAME_FILE=
SUMMARY_FILE=
EXPECTED_FAILURE=false

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
    --languages)
      LANGUAGES=${2-}
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
    --expected-failure)
      EXPECTED_FAILURE=true
      shift
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
  detect-only) CHECK_NAME='Detect Language' ;;
  *) CHECK_NAME=$CHECK ;;
esac

case "$LANGUAGE" in
  go) LANGUAGE_NAME=Go ;;
  python) LANGUAGE_NAME=Python ;;
  typescript)
    case "$FRAMEWORK" in
      next) LANGUAGE_NAME='Typescript - Next.js' ;;
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

if [[ "$EXPECTED_FAILURE" == true ]]; then
  TEST_SCENARIO="expected failure"
else
  TEST_SCENARIO=
fi

render_detected_languages() {
  local raw=$LANGUAGES
  local language label
  local -a detected=()

  if [[ "$raw" == \[*\] ]]; then
    raw=${raw:1:${#raw}-2}
  fi
  raw=${raw//\"/}

  if [[ -z "$raw" ]]; then
    printf 'Languages Detected: None\n'
    return
  fi

  printf 'Languages Detected:\n'
  IFS=',' read -r -a detected <<< "$raw"
  for language in "${detected[@]}"; do
    case "$language" in
      go) label=Go ;;
      python) label=Python ;;
      typescript) label=TypeScript ;;
      *) label=$language ;;
    esac
    printf -- '- %s\n' "$label"
  done
}

render_structured_error() {
  if grep -q '^Error:' "$ERROR_FILE"; then
    cat "$ERROR_FILE"
    return
  fi

  printf 'Error:\n```text\n'
  cat "$ERROR_FILE"
  printf '\n```\n'
}

render_structural_error() {
  local raw command_failure recent_output text_fence='```text' fence='```'

  if [[ ! -s "$ERROR_FILE" ]]; then
    printf 'Error:\nNone\n'
    return
  fi

  raw=$(<"$ERROR_FILE")
  if [[ "$raw" == *$'\n\nRecent output:\n'* ]]; then
    command_failure=${raw%%$'\n\nRecent output:\n'*}
    recent_output=${raw#*$'\n\nRecent output:\n'}
    printf 'Error:\n%s\n%s\n%s\n\nRecent output:\n%s\n%s\n%s\n' \
      "$text_fence" "$command_failure" "$fence" \
      "$text_fence" "$recent_output" "$fence"
  else
    printf 'Error:\n%s\n%s\n%s\n' "$text_fence" "$raw" "$fence"
  fi
}

printf '%s\n' "$SUMMARY_NAME" > "$NAME_FILE"
{
  printf '### Quality Gate: %s\n' "$SUMMARY_NAME"
  if [[ -f "$SUCCESS_FILE" ]]; then
    printf 'Outcome: success\n'
  else
    printf 'Outcome: failure\n'
  fi
  if [[ "$CHECK" == detect-only ]]; then
    if [[ -s "$ERROR_FILE" ]]; then
      error_message=$(<"$ERROR_FILE")
      printf 'Error: %s\n' "$error_message"
    else
      printf 'Error: None\n'
    fi
    render_detected_languages
  elif [[ "$CHECK" == app:typecheck || "$CHECK" == app:format || "$CHECK" == app:lint ]]; then
    if [[ -s "$ERROR_FILE" ]]; then
      render_structured_error
    else
      printf 'Error:\nNone\n'
    fi
  elif [[ "$CHECK" == app:strlint ]]; then
    render_structural_error
  else
    printf 'Error:\n'
    if [[ -s "$ERROR_FILE" ]]; then
      cat "$ERROR_FILE"
    else
      printf 'None\n'
    fi
  fi
  if [[ "$EXPECTED_FAILURE" == true ]]; then
    printf '\n## Test\n\n'
    printf 'Test scenario: %s\n' "$TEST_SCENARIO"
    if [[ -f "$SUCCESS_FILE" ]]; then
      printf 'Outcome: success\n'
    else
      printf 'Outcome: failure\n'
    fi
    printf 'Expected outcome: failure\n'
  fi
} > "$SUMMARY_FILE"

if [[ "$EXPECTED_FAILURE" == true && -f "$SUCCESS_FILE" ]]; then
  printf 'Quality gate succeeded unexpectedly for expected-failure scenario.\n' >&2
  exit 1
fi
