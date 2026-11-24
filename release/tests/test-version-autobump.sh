#!/usr/bin/env bash
# Runs the "Skip if no changes were made since last release" step of the
# reusable workflow .github/workflows/version-autobump.yml in a throwaway git
# repository, so the `skip` output it writes to $GITHUB_OUTPUT is checked
# without GitHub. The step script is read from the workflow and its GitHub
# expressions are replaced by the values each case gives. It runs as the
# runner runs a `shell: bash` step: bash --noprofile --norc -eo pipefail.
# Needs bash, git, awk, sed and grep.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workflow="${VERSION_AUTOBUMP_WORKFLOW:-$script_dir/../../.github/workflows/version-autobump.yml}"
step_name="Skip if no changes were made since last release"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# step_script: prints the `run: |` block of the step named $step_name of
# jobs.calculate, without its indentation; fails unless exactly one matches.
step_script() {
  awk -v name="$step_name" '
    /^  calculate:/ { in_job = 1; next }
    in_job && /^  [^ ]/ { in_job = 0 }
    !in_job { next }
    /^      - name: / {
      found = (substr($0, 15) == name)
      if (found) count++
      in_run = 0
      next
    }
    found && /^        run: \|/ { in_run = 1; next }
    found && in_run {
      if ($0 != "" && $0 !~ /^          /) { in_run = 0; next }
      print substr($0, 11)
    }
    END { if (count != 1) exit 1 }
  ' "$workflow"
}

script=$(step_script) || {
  printf 'FAIL: step "%s" of jobs.calculate not found exactly once in %s\n' "$step_name" "$workflow" >&2
  exit 1
}
[[ -n "$script" ]] || {
  printf 'FAIL: step "%s" has no run script\n' "$step_name" >&2
  exit 1
}

new_repo() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  mkdir -p "$repo/app" "$repo/docs"
  printf 'app\n' >"$repo/app/main.txt"
  printf 'docs\n' >"$repo/docs/readme.txt"
  git -C "$repo" add .
  git -C "$repo" commit -qm initial
}

# run_guard <repo> <ref name> <has_tag> <latest_tag> <context>: runs the step
# in <repo> as the runner runs a `shell: bash` step (bash --noprofile --norc
# -eo pipefail, working directory = the checkout)
# and sets guard_output to what it appended to $GITHUB_OUTPUT.
guard_output=""
# shellcheck disable=SC2016 # the opening of a GitHub expression, not a shell expansion
expression_open='${{'
run_guard() {
  local repo="$1" ref_name="$2" has_tag="$3" latest_tag="$4" context="$5"
  local rendered="$tmp_dir/guard.sh" output="$tmp_dir/github-output"
  # shellcheck disable=SC2016 # literal GitHub expressions, not shell variables
  printf '%s\n' "$script" | sed \
    -e 's|\${{ steps\.version\.outputs\.has_tag }}|'"$has_tag"'|g' \
    -e 's|\${{ steps\.version\.outputs\.latest_tag }}|'"$latest_tag"'|g' \
    -e 's|\${{ inputs\.context }}|'"$context"'|g' >"$rendered"
  if grep -qF "$expression_open" "$rendered"; then
    fail "the step uses a GitHub expression this test does not replace: $(grep -F "$expression_open" "$rendered")"
  fi
  : >"$output"
  (cd "$repo" && GITHUB_OUTPUT="$output" GITHUB_REF_NAME="$ref_name" bash --noprofile --norc -eo pipefail "$rendered" >/dev/null) ||
    fail "the step failed for ref $ref_name, has_tag $has_tag, tag $latest_tag, context $context"
  if [[ -e "$repo/GITHUB_OUTPUT" ]]; then
    fail "the step wrote a file named GITHUB_OUTPUT in the working directory instead of \$GITHUB_OUTPUT"
    rm -f "$repo/GITHUB_OUTPUT"
  fi
  guard_output=$(cat "$output")
}

# expect_skip <case> <expected value> <run_guard arguments...>
expect_skip() {
  local name="$1" expected="$2"
  shift 2
  run_guard "$@"
  [[ "$guard_output" == "skip=$expected" ]] ||
    fail "$name: expected \$GITHUB_OUTPUT to hold exactly skip=$expected, got '${guard_output//$'\n'/\\n}'"
}

repo="$tmp_dir/repository"
new_repo "$repo"
git -C "$repo" tag v1.2.3

expect_skip "no change in the context since the tag on main" true \
  "$repo" main true v1.2.3 app
expect_skip "no change in the whole repository since the tag on main" true \
  "$repo" main true v1.2.3 .

printf 'more docs\n' >>"$repo/docs/readme.txt"
git -C "$repo" commit -qam "docs change"

expect_skip "change outside the context since the tag on main" true \
  "$repo" main true v1.2.3 app
expect_skip "change in the context since the tag on main" false \
  "$repo" main true v1.2.3 docs
expect_skip "change in the whole repository since the tag on main" false \
  "$repo" main true v1.2.3 .
expect_skip "branch other than main" false \
  "$repo" feature true v1.2.3 app
expect_skip "first release, no tag" false \
  "$repo" main false '' app
expect_skip "tag that git diff cannot resolve" false \
  "$repo" main true v0.0.0-missing app

# A diff whose list of file names is far larger than a pipe buffer (64 KiB):
# a reader that stops at the first line must not turn it into "no changes".
for i in $(seq 1 4000); do
  printf 'x\n' >"$repo/app/a-file-with-a-long-enough-name-to-fill-the-pipe-$i.txt"
done
git -C "$repo" add app
git -C "$repo" commit -qm "many app files"

expect_skip "change in the context listing more than 64 KiB of file names" false \
  "$repo" main true v1.2.3 app

# Every write to the step outputs of the workflow goes to the file the
# runner reads, never to a relative path named GITHUB_OUTPUT.
if grep -nE '>>[[:space:]]*"?GITHUB_OUTPUT' "$workflow" >&2; then
  fail "a step appends to a file named GITHUB_OUTPUT instead of \"\$GITHUB_OUTPUT\""
fi

if ((failures > 0)); then
  printf '%d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "version-autobump guard tests passed"
