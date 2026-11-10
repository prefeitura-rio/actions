#!/usr/bin/env bash
# Portable tests for sast/scripts/normalize-ignores.sh. It is pure bash, awk,
# sed and coreutils, so it runs as is: every case gets a fresh directory with
# some of .semgrepignore, sonar-project.properties and .checkov.yaml, and the
# script runs there under `env -i` (LC_ALL=C, so `sort` is deterministic and
# no runner variable leaks in). The cases cover the priority of the source
# file, the extraction of each format, the files left untouched, the
# checkov-skip-paths.txt list and the glob <-> checkov regex translation in
# both directions.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
normalize="$script_dir/../scripts/normalize-ignores.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

out="$tmp_dir/stdout"
err="$tmp_dir/stderr"
status=0
case_dir=""

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [[ -s "$out" ]]; then
    printf -- '--- stdout\n%s\n' "$(<"$out")" >&2
  fi
  if [[ -s "$err" ]]; then
    printf -- '--- stderr\n%s\n' "$(<"$err")" >&2
  fi
  exit 1
}

# new_case <name>: a fresh, empty working directory for the next run.
new_case() {
  case_dir="$tmp_dir/cases/$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir"
}

# run_normalize: runs the script in the current case directory with only
# PATH, HOME and LC_ALL, capturing stdout, stderr and the status.
run_normalize() {
  status=0
  (cd "$case_dir" && env -i PATH="$PATH" HOME="$tmp_dir" LC_ALL=C \
    bash "$normalize") >"$out" 2>"$err" || status=$?
}

assert_status() {
  [[ "$status" == "$1" ]] || fail "$2: expected exit $1, got $status"
}

assert_stdout_equals() {
  [[ "$(<"$out")" == "$1" ]] || fail "$2: stdout is not:
$1"
}

# assert_file <name> <expected content> <context>
assert_file() {
  local path="$case_dir/$1"
  [[ -f "$path" ]] || fail "$3: $1 was not created"
  [[ "$(<"$path")" == "$2" ]] || fail "$3: unexpected $1:
$(<"$path")
expected:
$2"
}

assert_absent() {
  [[ ! -e "$case_dir/$1" ]] || fail "$2: $1 was created:
$(<"$case_dir/$1")"
}

# assert_unchanged <name> <original copy> <context>: byte-for-byte identical.
assert_unchanged() {
  cmp -s "$case_dir/$1" "$2" || fail "$3: $1 was modified:
$(<"$case_dir/$1")"
}

# assert_files <context> <name>...: the case directory holds exactly these.
assert_files() {
  local context="$1" actual expected
  shift
  actual=$(cd "$case_dir" && LC_ALL=C ls -A | LC_ALL=C sort)
  expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
  [[ "$actual" == "$expected" ]] || fail "$context: unexpected files:
$actual
expected:
$expected"
}

# --- fixtures ------------------------------------------------------------------

fixtures="$tmp_dir/fixtures"
mkdir -p "$fixtures"

# Globs authored by hand: comments, blank lines, surrounding spaces, a leading
# and a trailing slash, "**" at both ends and in the middle, "*" and "?", and
# regex metacharacters that must be escaped for checkov.
cat >"$fixtures/semgrepignore" <<'EOF'
# Generated assets
node_modules/
  **/vendor/**
*.min.js

docs/?.md
src/a+b(c).py
a/**/b
/build
node_modules/
EOF

semgrep_globs='**/vendor/**
*.min.js
/build
a/**/b
docs/?.md
node_modules/
src/a+b(c).py'

# The checkov regex of each glob above, in the same order.
semgrep_regexes='vendor
[^/]*\.min\.js
build
a/.*/b
docs/.\.md
node_modules
src/a\+b\(c\)\.py'

# What checkov-skip-paths.txt holds for them: the same regexes, sorted.
semgrep_skip_paths='[^/]*\.min\.js
a/.*/b
build
docs/.\.md
node_modules
src/a\+b\(c\)\.py
vendor'

cat >"$fixtures/sonar-project.properties" <<'EOF'
sonar.projectKey=demo
# sonar.exclusions=commented/**
sonar.exclusions=dist/**, \
    coverage/**,\
    **/*.generated.ts
sonar.test.exclusions=tests/**
sonar.coverage.exclusions=dist/**
sonar.sources=src
EOF

sonar_globs='**/*.generated.ts
coverage/**
dist/**
tests/**'

# A hand-written .checkov.yaml: other keys around the skip-path block,
# single- and double-quoted entries, a trailing comment, a comment and a
# blank line inside the block, and a hand-written regex construct.
cat >"$fixtures/checkov.yaml" <<'EOF'
# checkov configuration
framework:
  - terraform
skip-path:
  - "vendor"
  - 'node_modules'   # dependencies
  # comment inside the block
  - tests/(unit|e2e)

  - build\.out
soft-fail: true
  - not-a-skip-path
EOF

checkov_regexes='build\.out
node_modules
tests/(unit|e2e)
vendor'

# semgrep_file <source> <globs, one per line>: a generated .semgrepignore.
semgrep_file() {
  printf '# Auto-generated from %s\n\n%s' "$1" "$2"
}

# sonar_file <source> <globs, one per line>: a generated
# sonar-project.properties.
sonar_file() {
  printf '# Auto-generated from %s\n\nsonar.exclusions=%s' "$1" "$(printf '%s\n' "$2" | paste -sd , -)"
}

# checkov_file <source> <regexes, one per line>: a generated .checkov.yaml.
checkov_file() {
  local source="$1" regex
  printf '# Auto-generated from %s\nskip-path:' "$source"
  while IFS= read -r regex; do
    printf "\n  - '%s'" "$regex"
  done <<<"$2"
}

# --- no ignore file --------------------------------------------------------------

new_case none
run_normalize
assert_status 0 'no ignore file'
assert_stdout_equals '' 'no ignore file'
assert_files 'no ignore file' checkov-skip-paths.txt
assert_file checkov-skip-paths.txt '' 'no ignore file'

# --- .semgrepignore only -----------------------------------------------------------

new_case semgrep-only
cp "$fixtures/semgrepignore" "$case_dir/.semgrepignore"
run_normalize
assert_status 0 '.semgrepignore only'
assert_stdout_equals 'Generated sonar-project.properties
Generated .checkov.yaml' '.semgrepignore only'
assert_unchanged .semgrepignore "$fixtures/semgrepignore" '.semgrepignore only'
assert_file sonar-project.properties "$(sonar_file .semgrepignore "$semgrep_globs")" '.semgrepignore only'
assert_file .checkov.yaml "$(checkov_file .semgrepignore "$semgrep_regexes")" '.semgrepignore only'
assert_file checkov-skip-paths.txt "$semgrep_skip_paths" '.semgrepignore only'
assert_files '.semgrepignore only' .semgrepignore sonar-project.properties .checkov.yaml checkov-skip-paths.txt
generated_checkov="$tmp_dir/generated-checkov.yaml"
cp "$case_dir/.checkov.yaml" "$generated_checkov"

# --- sonar-project.properties only -------------------------------------------------

# Continuation lines, the three exclusion keys, comments and duplicates.
new_case sonar-only
cp "$fixtures/sonar-project.properties" "$case_dir/sonar-project.properties"
run_normalize
assert_status 0 'sonar-project.properties only'
assert_stdout_equals 'Generated .semgrepignore
Generated .checkov.yaml' 'sonar-project.properties only'
assert_unchanged sonar-project.properties "$fixtures/sonar-project.properties" \
  'sonar-project.properties only'
assert_file .semgrepignore "$(semgrep_file sonar-project.properties "$sonar_globs")" \
  'sonar-project.properties only'
assert_file .checkov.yaml "$(checkov_file sonar-project.properties '[^/]*\.generated\.ts
coverage
dist
tests')" 'sonar-project.properties only'
assert_file checkov-skip-paths.txt '[^/]*\.generated\.ts
coverage
dist
tests' 'sonar-project.properties only'

# --- .checkov.yaml only (regex -> glob) --------------------------------------------

# Only the skip-path block is read; our own escaping is undone, a hand-written
# construct passes through unchanged, and every glob gets the "**/" prefix
# because checkov matches anywhere in the path.
new_case checkov-only
cp "$fixtures/checkov.yaml" "$case_dir/.checkov.yaml"
run_normalize
assert_status 0 '.checkov.yaml only'
assert_stdout_equals 'Generated .semgrepignore
Generated sonar-project.properties' '.checkov.yaml only'
assert_unchanged .checkov.yaml "$fixtures/checkov.yaml" '.checkov.yaml only'
checkov_globs='**/build.out
**/node_modules
**/tests/(unit|e2e)
**/vendor'
assert_file .semgrepignore "$(semgrep_file .checkov.yaml "$checkov_globs")" '.checkov.yaml only'
assert_file sonar-project.properties "$(sonar_file .checkov.yaml "$checkov_globs")" '.checkov.yaml only'
assert_file checkov-skip-paths.txt "$checkov_regexes" '.checkov.yaml only'

# --- round trips -------------------------------------------------------------------

# glob -> regex -> glob: the .checkov.yaml generated from .semgrepignore,
# alone, yields every original glob back, normalized (no leading or trailing
# "/", no "**/" or "/**" at the ends) and prefixed with "**/".
new_case round-trip-glob
cp "$generated_checkov" "$case_dir/.checkov.yaml"
run_normalize
assert_status 0 'glob -> regex -> glob'
round_trip_globs='**/*.min.js
**/a/**/b
**/build
**/docs/?.md
**/node_modules
**/src/a+b(c).py
**/vendor'
assert_file .semgrepignore "$(semgrep_file .checkov.yaml "$round_trip_globs")" 'glob -> regex -> glob'
assert_file sonar-project.properties "$(sonar_file .checkov.yaml "$round_trip_globs")" \
  'glob -> regex -> glob'
assert_file checkov-skip-paths.txt "$semgrep_skip_paths" 'glob -> regex -> glob'
round_trip_semgrep="$tmp_dir/round-trip-semgrepignore"
cp "$case_dir/.semgrepignore" "$round_trip_semgrep"

# regex -> glob -> regex: the .semgrepignore derived above, alone, yields the
# very same checkov regexes, so the translation is a fixed point.
new_case round-trip-regex
cp "$round_trip_semgrep" "$case_dir/.semgrepignore"
run_normalize
assert_status 0 'regex -> glob -> regex'
assert_file checkov-skip-paths.txt "$semgrep_skip_paths" 'regex -> glob -> regex'
assert_file .checkov.yaml "$(checkov_file .semgrepignore "$semgrep_skip_paths")" \
  'regex -> glob -> regex'

# --- priority of the source file ---------------------------------------------------

# .semgrepignore wins over sonar-project.properties: only the missing
# .checkov.yaml is generated, from .semgrepignore; sonar is left as is.
new_case semgrep-and-sonar
cp "$fixtures/semgrepignore" "$case_dir/.semgrepignore"
cp "$fixtures/sonar-project.properties" "$case_dir/sonar-project.properties"
run_normalize
assert_status 0 '.semgrepignore and sonar-project.properties'
assert_stdout_equals 'Generated .checkov.yaml' '.semgrepignore and sonar-project.properties'
assert_unchanged .semgrepignore "$fixtures/semgrepignore" '.semgrepignore and sonar-project.properties'
assert_unchanged sonar-project.properties "$fixtures/sonar-project.properties" \
  '.semgrepignore and sonar-project.properties'
assert_file .checkov.yaml "$(checkov_file .semgrepignore "$semgrep_regexes")" \
  '.semgrepignore and sonar-project.properties'
assert_file checkov-skip-paths.txt "$semgrep_skip_paths" '.semgrepignore and sonar-project.properties'

# .semgrepignore wins over .checkov.yaml: sonar comes from .semgrepignore,
# while checkov-skip-paths.txt still reflects the pre-existing .checkov.yaml.
new_case semgrep-and-checkov
cp "$fixtures/semgrepignore" "$case_dir/.semgrepignore"
cp "$fixtures/checkov.yaml" "$case_dir/.checkov.yaml"
run_normalize
assert_status 0 '.semgrepignore and .checkov.yaml'
assert_stdout_equals 'Generated sonar-project.properties' '.semgrepignore and .checkov.yaml'
assert_unchanged .semgrepignore "$fixtures/semgrepignore" '.semgrepignore and .checkov.yaml'
assert_unchanged .checkov.yaml "$fixtures/checkov.yaml" '.semgrepignore and .checkov.yaml'
assert_file sonar-project.properties "$(sonar_file .semgrepignore "$semgrep_globs")" \
  '.semgrepignore and .checkov.yaml'
assert_file checkov-skip-paths.txt "$checkov_regexes" '.semgrepignore and .checkov.yaml'

# sonar-project.properties wins over .checkov.yaml.
new_case sonar-and-checkov
cp "$fixtures/sonar-project.properties" "$case_dir/sonar-project.properties"
cp "$fixtures/checkov.yaml" "$case_dir/.checkov.yaml"
run_normalize
assert_status 0 'sonar-project.properties and .checkov.yaml'
assert_stdout_equals 'Generated .semgrepignore' 'sonar-project.properties and .checkov.yaml'
assert_unchanged sonar-project.properties "$fixtures/sonar-project.properties" \
  'sonar-project.properties and .checkov.yaml'
assert_unchanged .checkov.yaml "$fixtures/checkov.yaml" 'sonar-project.properties and .checkov.yaml'
assert_file .semgrepignore "$(semgrep_file sonar-project.properties "$sonar_globs")" \
  'sonar-project.properties and .checkov.yaml'
assert_file checkov-skip-paths.txt "$checkov_regexes" 'sonar-project.properties and .checkov.yaml'

# All three present: nothing is generated or rewritten.
new_case all-three
cp "$fixtures/semgrepignore" "$case_dir/.semgrepignore"
cp "$fixtures/sonar-project.properties" "$case_dir/sonar-project.properties"
cp "$fixtures/checkov.yaml" "$case_dir/.checkov.yaml"
run_normalize
assert_status 0 'all three files'
assert_stdout_equals '' 'all three files'
assert_unchanged .semgrepignore "$fixtures/semgrepignore" 'all three files'
assert_unchanged sonar-project.properties "$fixtures/sonar-project.properties" 'all three files'
assert_unchanged .checkov.yaml "$fixtures/checkov.yaml" 'all three files'
assert_file checkov-skip-paths.txt "$checkov_regexes" 'all three files'
assert_files 'all three files' .semgrepignore sonar-project.properties .checkov.yaml checkov-skip-paths.txt

# A stale checkov-skip-paths.txt is always rewritten from .checkov.yaml.
new_case stale-skip-paths
printf 'stale\n' >"$case_dir/checkov-skip-paths.txt"
run_normalize
assert_status 0 'stale checkov-skip-paths.txt'
assert_file checkov-skip-paths.txt '' 'stale checkov-skip-paths.txt'
assert_absent .semgrepignore 'stale checkov-skip-paths.txt'

printf 'normalize-ignores tests passed\n'
