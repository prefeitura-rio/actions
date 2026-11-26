#!/usr/bin/env bash
# Tests ci-github-actions-mutable-action-tag (opengrep-rules/ci/) with the real
# opengrep against workflow and composite action fixtures written here: it
# flags every mutable `uses:` of a step, as the p/default rule it replaces
# does, except refs to prefeitura-rio/actions (DEV-757). Only the local rules
# are loaded, so no registry or network is used.
#
# Needs opengrep on PATH (the version pinned in scripts/prepare-tool-cache.sh);
# exits with status 2 when it is missing.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rules="$script_dir/../opengrep-rules/ci/"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if ! command -v opengrep >/dev/null; then
  echo 'opengrep is not installed' >&2
  exit 2
fi
command -v jq >/dev/null || fail 'jq is not installed'

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

target="$tmp_dir/repo"
mkdir -p "$target/.github/workflows" "$target/actions/setup"

cat >"$target/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
jobs:
  sast:
    uses: prefeitura-rio/actions/.github/workflows/sast.yml@master
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bridgecrewio/checkov-action@master
      - uses: aquasecurity/trivy-action@0.29.0
      - uses: prefeitura-rio/actions/sast@master
      - uses: "prefeitura-rio/actions/quality-gate/python@latest"
      - uses: Prefeitura-Rio/Actions/setup-devenv@v1.2.3
      - uses: prefeitura-rio/actions@quality-gate-latest
      - uses: prefeitura-rio/actions-evil/sast@master
      - uses: prefeitura-rio/other-repo@main
      - uses: evil/prefeitura-rio/actions/sast@master
      - uses: actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608
      - uses: ./actions/setup
      - uses: docker://alpine:3.18
      # uses: actions/setup-node@v4
YAML

cat >"$target/actions/setup/action.yml" <<'YAML'
name: Setup
runs:
  using: composite
  steps:
    - uses: actions/setup-go@v5
    - uses: prefeitura-rio/actions/setup-devenv@master
YAML

expected=$(
  LC_ALL=C sort <<'EOF'
actions/setup/action.yml:actions/setup-go@v5
.github/workflows/ci.yml:actions/checkout@v4
.github/workflows/ci.yml:aquasecurity/trivy-action@0.29.0
.github/workflows/ci.yml:bridgecrewio/checkov-action@master
.github/workflows/ci.yml:evil/prefeitura-rio/actions/sast@master
.github/workflows/ci.yml:prefeitura-rio/actions-evil/sast@master
.github/workflows/ci.yml:prefeitura-rio/other-repo@main
EOF
)

report="$tmp_dir/report.json"
(cd "$target" && LANG=C.UTF-8 LC_ALL=C.UTF-8 opengrep scan . --quiet \
  --config "$rules" --json-output="$report" >/dev/null) || fail 'opengrep scan failed'

errors=$(jq '.errors | length' "$report")
[[ "$errors" == 0 ]] || fail "opengrep reported errors: $(jq -c '.errors' "$report")"

other=$(jq -r '.results[].check_id | select(endswith(".ci-github-actions-mutable-action-tag") | not)' "$report")
[[ -z "$other" ]] || fail "unexpected rules matched the fixtures: $other"

actual=$(jq -r '.results[] | "\(.path):\(.extra.lines | sub("^\\s*- uses: \"?"; "") | sub("\"?\\s*$"; ""))"' "$report" | LC_ALL=C sort)
if [[ "$actual" != "$expected" ]]; then
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  fail 'ci-github-actions-mutable-action-tag findings differ'
fi

echo 'PASS: ci-github-actions-mutable-action-tag'
