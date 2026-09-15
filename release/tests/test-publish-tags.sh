#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
validate_target="$script_dir/../scripts/validate-target.sh"
publish_tags="$script_dir/../scripts/publish-tags.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

remote="$tmp_dir/remote.git"
repo="$tmp_dir/repository"
git init -q --bare "$remote"
git init -q -b master "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
printf 'initial\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q -u origin master

target_sha=$(git -C "$repo" rev-parse HEAD)
short_target_sha=$(git -C "$repo" rev-parse --short HEAD)
validation=$(bash "$validate_target" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$short_target_sha")
[[ "$validation" == *'skip=false'* ]]

publish_output=$(bash "$publish_tags" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$target_sha" \
  --version-tag v1.0.0 \
  --floating-tag latest)
[[ "$publish_output" == $'version_tag=v1.0.0\nfloating_tag=latest' ]]

bash "$publish_tags" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$target_sha" \
  --version-tag v1.0.0 \
  --floating-tag latest

version_sha=$(git --git-dir "$remote" rev-list -n 1 refs/tags/v1.0.0)
latest_sha=$(git --git-dir "$remote" rev-list -n 1 refs/tags/latest)
[[ "$version_sha" == "$target_sha" ]]
[[ "$latest_sha" == "$target_sha" ]]
[[ "$(git --git-dir "$remote" cat-file -t refs/tags/latest)" == tag ]]
[[ "$(git --git-dir "$remote" for-each-ref --format='%(contents)' refs/tags/latest)" == 'Latest release: v1.0.0' ]]

latest_message=$(git --git-dir "$remote" for-each-ref --format='%(contents)' refs/tags/latest)

printf 'second\n' >> "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm second
git -C "$repo" push -q origin master
new_target_sha=$(git -C "$repo" rev-parse HEAD)

stale_validation=$(bash "$validate_target" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$target_sha")
[[ "$stale_validation" == *'skip=true'* ]]

if bash "$publish_tags" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$target_sha" \
  --version-tag v1.0.1 \
  --floating-tag latest; then
  printf 'Expected stale target publication to fail\n' >&2
  exit 1
fi
if git --git-dir "$remote" rev-parse --verify refs/tags/v1.0.1 >/dev/null 2>&1; then
  printf 'Stale target publication created a version tag\n' >&2
  exit 1
fi
if git -C "$repo" rev-parse --verify refs/tags/v1.0.1 >/dev/null 2>&1; then
  printf 'Stale target publication left a local version tag\n' >&2
  exit 1
fi
[[ "$(git --git-dir "$remote" for-each-ref --format='%(contents)' refs/tags/latest)" == "$latest_message" ]]
[[ "$(git --git-dir "$remote" cat-file -t refs/tags/latest)" == tag ]]

target_sha="$new_target_sha"

bash "$publish_tags" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$target_sha" \
  --version-tag v1.0.1 \
  --floating-tag latest

latest_sha=$(git --git-dir "$remote" rev-list -n 1 refs/tags/latest)
[[ "$latest_sha" == "$target_sha" ]]
[[ "$(git --git-dir "$remote" cat-file -t refs/tags/latest)" == tag ]]
[[ "$(git --git-dir "$remote" for-each-ref --format='%(contents)' refs/tags/latest)" == 'Latest release: v1.0.1' ]]

printf 'tag publication tests passed\n'
