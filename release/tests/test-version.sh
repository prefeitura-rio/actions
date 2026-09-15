#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
calculate_version="$script_dir/../scripts/calculate-version.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

new_repo() {
  local repo="$1"
  git init -q -b master "$repo"
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  printf 'initial\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm initial
}

assert_output() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || {
    printf 'Expected output to contain %s, got:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

repo="$tmp_dir/repository"
mkdir -p "$repo"
new_repo "$repo"
target_sha=$(git -C "$repo" rev-parse HEAD)

output=$(bash "$calculate_version" --repository "$repo" --target-sha "$target_sha")
assert_output "$output" 'version=1.0.0'
assert_output "$output" 'version_tag=v1.0.0'

git -C "$repo" tag v1.2.3
git -C "$repo" tag v9.0.0-rc.1
printf 'second\n' >> "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm second
target_sha=$(git -C "$repo" rev-parse HEAD)
short_target_sha=$(git -C "$repo" rev-parse --short HEAD)

output=$(bash "$calculate_version" --repository "$repo" --target-sha "$short_target_sha" --bump patch)
assert_output "$output" 'version=1.2.4'
assert_output "$output" 'version_tag=v1.2.4'

git -C "$repo" tag v2.0.0 "$target_sha"
output=$(bash "$calculate_version" --repository "$repo" --target-sha "$target_sha")
assert_output "$output" 'version=2.0.0'
assert_output "$output" 'version_tag=v2.0.0'

printf 'version calculation tests passed\n'
