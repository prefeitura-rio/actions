#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURES="$ROOT/fixtures"
ERROR_FILE=$(mktemp)
SUCCESS_FILE=$(mktemp)
SUMMARY_NAME_FILE=$(mktemp)
SUMMARY_FILE=$(mktemp)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$ERROR_FILE" "$SUCCESS_FILE" "$SUMMARY_NAME_FILE" "$SUMMARY_FILE" "$TEMP_DIR"' EXIT

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

if QUALITY_GATE_ERROR_FILE="$ERROR_FILE" bash "$ROOT/scripts/detect-languages.sh" --check app:format --working-directory "$FIXTURES/error/multiple-languages"; then
  fail "multiple languages without override should be rejected for normal check"
fi
assert_equal \
  "Multiple supported languages detected: go python typescript. Run quality-gate once per language, or use the detect-only check to enumerate languages." \
  "$(<"$ERROR_FILE")" \
  "multi-language normal check rejection diagnostic"

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

: > "$ERROR_FILE"
touch "$SUCCESS_FILE"
bash "$ROOT/scripts/render-summary.sh" \
  --check detect-only \
  --languages '["go"]' \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
assert_equal "Detect Language" "$(<"$SUMMARY_NAME_FILE")" "single-language summary name"
assert_equal \
  $'### Quality Gate: Detect Language\nOutcome: success\nError: None\nLanguages Detected:\n- Go' \
  "$(<"$SUMMARY_FILE")" \
  "single-language summary layout"

bash "$ROOT/scripts/render-summary.sh" \
  --check detect-only \
  --languages '["go","python","typescript"]' \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
assert_contains "$(<"$SUMMARY_FILE")" "- Go" "multi-language summary Go entry"
assert_contains "$(<"$SUMMARY_FILE")" "- Python" "multi-language summary Python entry"
assert_contains "$(<"$SUMMARY_FILE")" "- TypeScript" "multi-language summary TypeScript entry"

rm -f "$SUCCESS_FILE"
printf '%s\n' "Could not detect a supported language." > "$ERROR_FILE"
bash "$ROOT/scripts/render-summary.sh" \
  --check detect-only \
  --languages '[]' \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
assert_contains "$(<"$SUMMARY_FILE")" "Outcome: failure" "no-language summary outcome"
assert_contains "$(<"$SUMMARY_FILE")" "Error: Could not detect a supported language." "no-language summary error"
assert_contains "$(<"$SUMMARY_FILE")" "Languages Detected: None" "no-language summary languages"

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
  --max-bytes 8)
assert_contains "$collected" "... error output truncated" "error truncation"
assert_contains "$collected" "0123456" "dynamic truncation head"
assert_contains "$collected" "9" "dynamic truncation tail"

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

bash "$ROOT/scripts/render-summary.sh" \
  --check app:format \
  --language typescript \
  --framework next \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
assert_equal "Format (Typescript - Next.js)" "$(<"$SUMMARY_NAME_FILE")" "Next.js summary name"

(
  export QUALITY_GATE_ERROR_FILE="$ERROR_FILE"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib/diagnostics.sh"
  qg_typecheck_error \
    uv \
    'uv sync --frozen --all-groups' \
    $'setup noise\nerror: The lockfile needs to be updated.\nhint: To update the lockfile, run uv lock.'
) 2>/dev/null
rm -f "$SUCCESS_FILE"
bash "$ROOT/scripts/render-summary.sh" \
  --check app:typecheck \
  --language python \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$SUMMARY_FILE"
typecheck_summary=$(<"$SUMMARY_FILE")
assert_contains "$typecheck_summary" "#### Error" "typecheck diagnostic box"
assert_contains "$typecheck_summary" "error: The lockfile needs to be updated." "typecheck tool diagnostic"
assert_contains "$typecheck_summary" "hint: To update the lockfile, run uv lock." "typecheck tool hint"
assert_contains "$typecheck_summary" "uv sync --frozen --all-groups" "typecheck expected command"
if [[ "$typecheck_summary" == *"Recent output:"* || "$typecheck_summary" == *"setup noise"* ]]; then
  fail "typecheck summary should omit capture noise"
fi

capture_env="$TEMP_DIR/bash-env"
capture_log="$TEMP_DIR/capture.log"
printf 'QUALITY_GATE_ERROR_FILE=%q\nQUALITY_GATE_OUTPUT_LOG=%q\nsource %q\n' \
  "$ERROR_FILE" "$capture_log" "$ROOT/scripts/capture-failure.sh" > "$capture_env"
BASH_ENV="$capture_env" bash -c 'printf "outer\\n"; bash -c '\''printf "inner\\n"'\''' >/dev/null
assert_equal "1" "$(awk '$0 == "outer" { count++ } END { print count + 0 }' "$capture_log")" "outer capture count"
assert_equal "1" "$(awk '$0 == "inner" { count++ } END { print count + 0 }' "$capture_log")" "nested capture count"

EXPECTED_FAILURE_SUMMARY=$(mktemp)
bash "$ROOT/scripts/render-summary.sh" \
  --check app:typecheck \
  --language python \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$EXPECTED_FAILURE_SUMMARY" \
  --expected-failure
assert_equal "Type Check (Python)" "$(<"$SUMMARY_NAME_FILE")" "expected-failure summary name"
assert_contains "$(<"$EXPECTED_FAILURE_SUMMARY")" "## Test" "expected-failure section"
assert_contains "$(<"$EXPECTED_FAILURE_SUMMARY")" "Test scenario: expected failure" "expected-failure scenario"
assert_contains "$(<"$EXPECTED_FAILURE_SUMMARY")" "Outcome: failure" "expected-failure outcome"
assert_contains "$(<"$EXPECTED_FAILURE_SUMMARY")" "Expected outcome: failure" "expected-failure expected outcome"

touch "$SUCCESS_FILE"
: > "$ERROR_FILE"
if bash "$ROOT/scripts/render-summary.sh" \
  --check app:typecheck \
  --language python \
  --error-file "$ERROR_FILE" \
  --success-file "$SUCCESS_FILE" \
  --name-file "$SUMMARY_NAME_FILE" \
  --summary-file "$EXPECTED_FAILURE_SUMMARY" \
  --expected-failure 2>/dev/null; then
  fail "render-summary.sh should fail when expected failure unexpectedly succeeds"
fi
assert_contains "$(<"$EXPECTED_FAILURE_SUMMARY")" "Outcome: success" "expected-failure dynamic success outcome"
rm -f "$EXPECTED_FAILURE_SUMMARY" "$SUCCESS_FILE"

project_info=$(node "$ROOT/typescript/scripts/project-info.js" "$ROOT/typescript/fixtures/vue/pass")
assert_contains "$project_info" "framework=vue" "Vue framework detection"
assert_contains "$project_info" "react=false" "React detection"

project_info=$(node "$ROOT/typescript/scripts/project-info.js" "$ROOT/typescript/fixtures/next/pass")
assert_contains "$project_info" "framework=next" "Next.js framework detection"
assert_contains "$project_info" "react=true" "Next.js React detection"

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

printf '{"name": "test", "packageManager": "pnpm@"}' > "$TEMP_DIR/package.json"
touch "$TEMP_DIR/pnpm-lock.yaml"
if node "$ROOT/typescript/scripts/project-info.js" "$TEMP_DIR" --require-package-manager 2>"$ERROR_FILE"; then
  fail "TypeScript project with empty pnpm version should be rejected"
fi
assert_equal \
  "package.json must declare packageManager as pnpm@<version>." \
  "$(<"$ERROR_FILE")" \
  "empty-pnpm-version diagnostic"

printf '{"name": "test", "packageManager": "pnpm@10.15.0\\nmanager=npm"}' > "$TEMP_DIR/package.json"
if node "$ROOT/typescript/scripts/project-info.js" "$TEMP_DIR" --require-package-manager 2>"$ERROR_FILE"; then
  fail "TypeScript project with newline in packageManager should be rejected"
fi
assert_equal \
  "package.json must declare packageManager as pnpm@<version>." \
  "$(<"$ERROR_FILE")" \
  "newline-package-manager diagnostic"

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
