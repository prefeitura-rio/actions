#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURES="$ROOT/fixtures"
ERROR_FILE=$(mktemp)
SUCCESS_FILE=$(mktemp)
SUMMARY_NAME_FILE=$(mktemp)
SUMMARY_FILE=$(mktemp)
trap 'rm -f "$ERROR_FILE" "$SUCCESS_FILE" "$SUMMARY_NAME_FILE" "$SUMMARY_FILE"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local message=$3
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local value=$1
  local expected=$2
  local message=$3
  [[ "$value" == *"$expected"* ]] || fail "$message: missing '$expected'"
}

unset GITHUB_ACTION_PATH GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY RUNNER_TEMP RUNNER_TOOL_CACHE

assert_equal \
  "name=go" \
  "$(bash "$ROOT/scripts/detect-languages.sh" --check app:format --working-directory "$FIXTURES/../go/fixtures/pass")" \
  "single-language detection"

assert_equal \
  'languages=["go","python","typescript"]' \
  "$(bash "$ROOT/scripts/detect-languages.sh" --check detect-only --working-directory "$FIXTURES/error/multiple-languages")" \
  "multi-language detection"

assert_equal \
  "name=go" \
  "$(bash "$ROOT/scripts/detect-languages.sh" --check app:format --language go --working-directory "$FIXTURES/../go/fixtures/pass")" \
  "matching language override"

if QUALITY_GATE_ERROR_FILE="$ERROR_FILE" bash "$ROOT/scripts/detect-languages.sh" --check app:format --language python --working-directory "$FIXTURES/../go/fixtures/pass"; then
  fail "mismatched language override should be rejected"
fi
assert_equal \
  "Requested language 'python' not detected in project. Detected: go." \
  "$(<"$ERROR_FILE")" \
  "mismatched language diagnostic"

if QUALITY_GATE_ERROR_FILE="$ERROR_FILE" bash "$ROOT/scripts/detect-languages.sh" --check app:format --working-directory "$FIXTURES/error/no-language"; then
  fail "empty project should not detect a language"
fi
assert_equal \
  "Could not detect a supported language. Expected go.mod, pyproject.toml, or package.json+tsconfig.json." \
  "$(<"$ERROR_FILE")" \
  "no-language diagnostic"

if QUALITY_GATE_ERROR_FILE="$ERROR_FILE" bash "$ROOT/scripts/validate-check.sh" 'app:[f]ormat'; then
  fail "invalid check should be rejected"
fi
assert_equal \
  "Invalid check 'app:[f]ormat'. Valid values: app:format app:lint app:strlint app:typecheck app:test detect-only" \
  "$(<"$ERROR_FILE")" \
  "invalid-check diagnostic"

printf '0123456789' > "$ERROR_FILE"
rm -f "$SUCCESS_FILE"
collected=$(bash "$ROOT/scripts/collect-error.sh" \
  --check app:format \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --max-bytes 5)
assert_contains "$collected" "... error output truncated" "error truncation"

bash "$ROOT/scripts/render-summary.sh" \
  --check app:format \
  --language typescript \
  --framework vue \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
assert_equal "Format (Typescript - Vue)" "$(<"$SUMMARY_NAME_FILE")" "summary name"
assert_contains "$(<"$SUMMARY_FILE")" "Outcome: failure" "summary outcome"

project_info=$(node "$ROOT/typescript/scripts/project-info.js" "$ROOT/typescript/fixtures/vue/pass")
assert_contains "$project_info" "framework=vue" "Vue framework detection"
assert_contains "$project_info" "react=false" "React detection"

project_info=$(node "$ROOT/typescript/scripts/project-info.js" "$ROOT/typescript/fixtures/nuxt/pass" --check app:test)
assert_contains "$project_info" "manager=pnpm" "pnpm detection"
assert_contains "$project_info" "version=10.15.0" "pnpm version detection"
assert_contains "$project_info" "framework=nuxt" "Nuxt framework detection"

project_info_flags_first=$(node "$ROOT/typescript/scripts/project-info.js" --check app:test "$ROOT/typescript/fixtures/nuxt/pass")
assert_equal "$project_info" "$project_info_flags_first" "project-info flags-first argument parsing"

project_info_named_dir=$(node "$ROOT/typescript/scripts/project-info.js" --check app:test --working-directory "$ROOT/typescript/fixtures/nuxt/pass")
assert_equal "$project_info" "$project_info_named_dir" "project-info --working-directory argument parsing"

if node "$ROOT/typescript/scripts/project-info.js" "$FIXTURES/error/ts-no-lockfile" --require-package-manager 2>"$ERROR_FILE"; then
  fail "TypeScript project without lockfile should be rejected"
fi
assert_equal \
  "No lockfile found for TypeScript project. Commit pnpm-lock.yaml (pnpm) or package-lock.json (npm)." \
  "$(<"$ERROR_FILE")" \
  "missing-lockfile diagnostic"

for script in \
  "$ROOT/go/scripts/check.sh" \
  "$ROOT/python/scripts/check.sh" \
  "$ROOT/typescript/scripts/check.sh"; do
  if QUALITY_GATE_ERROR_FILE="$ERROR_FILE" bash "$script" --check invalid; then
    fail "$script should reject an unknown check"
  fi
  assert_equal "Unknown check: invalid" "$(<"$ERROR_FILE")" "$(basename "$(dirname "$script")") check contract"
done

printf 'portable quality-gate script tests passed\n'
