#!/usr/bin/env bash
# shellcheck disable=SC2016 # single quotes are intentional: literal workflow YAML with ${{ }} expressions
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
CHECK="$ROOT/.github/scripts/check-reusable-workflow-refs.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_workflow() {
  local name=$1
  local steps=$2
  local trigger=${3:-workflow_call}
  local dir="$TEMP_DIR/$name"
  mkdir -p "$dir"
  cat >"$dir/reusable.yml" <<EOF
on:
  $trigger:
jobs:
  job:
    runs-on: ubuntu-latest
    steps:
$steps
EOF
  printf '%s\n' "$dir"
}

expect_pass() {
  local name=$1
  local steps=$2
  local dir output
  dir=$(write_workflow "$name" "$steps")
  output=$(bash "$CHECK" "$dir" 2>&1) || fail "$name: expected pass, got: $output"
}

expect_reject() {
  local name=$1
  local steps=$2
  local expected=$3
  local dir output
  dir=$(write_workflow "$name" "$steps")
  if output=$(bash "$CHECK" "$dir" 2>&1); then
    fail "$name: expected rejection"
  fi
  [[ "$output" == *"$expected"* ]] || fail "$name: missing '$expected' in: $output"
}

output=$(bash "$CHECK" "$ROOT/.github/workflows" 2>&1) ||
  fail "repository reusable workflows still use mutable internal refs: $output"

expect_pass "self-repository action" '      - uses: $/sast'

expect_pass "pinned checkout of the workflow commit" '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}'

expect_pass "master-only floating tag" "      - id: latest
        if: endsWith(job.workflow_ref, '@refs/heads/master')
        uses: prefeitura-rio/actions/quality-gate@quality-gate-latest
      - id: pinned
        if: \${{ !endsWith(job.workflow_ref, '@refs/heads/master') }}
        uses: \$/quality-gate"

expect_reject "action on master" '      - uses: prefeitura-rio/actions/sast@master' \
  "internal action pinned to a mutable ref"

expect_reject "action on floating tag" '      - name: Detect
        uses: prefeitura-rio/actions/quality-gate@quality-gate-latest' \
  "internal action pinned to a mutable ref"

expect_reject "negated guard does not pin" "      - if: \${{ !endsWith(job.workflow_ref, '@refs/heads/master') }}
        uses: prefeitura-rio/actions/quality-gate@quality-gate-latest" \
  "internal action pinned to a mutable ref"

expect_reject "guard of another step" "      - if: endsWith(job.workflow_ref, '@refs/heads/master')
        run: true
      - uses: prefeitura-rio/actions/sast@master" \
  "internal action pinned to a mutable ref"

expect_reject "checkout by repository name" '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: prefeitura-rio/actions
          ref: ${{ job.workflow_sha }}' \
  "checkout of this repository by name"

expect_reject "checkout of master" '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: ${{ job.workflow_repository }}
          ref: master' \
  "checkout of a mutable branch"

expect_reject "hardcoded builder ref" '      - run: true
        env:
          BUILDER_ID: https://github.com/prefeitura-rio/actions/.github/workflows/build-and-release.yml@refs/heads/master' \
  "hardcoded refs/heads/master"

non_reusable=$(write_workflow "non-reusable" '      - uses: prefeitura-rio/actions/sast@master' push)
output=$(bash "$CHECK" "$non_reusable" 2>&1) || fail "non-reusable workflow should be ignored: $output"

if bash "$CHECK" "$TEMP_DIR/missing" 2>/dev/null; then
  fail "missing directory should be rejected"
fi

echo "check-reusable-workflow-refs tests passed"
