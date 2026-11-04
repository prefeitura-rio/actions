#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
move_floating_tag="$script_dir/../scripts/move-floating-tag.sh"
publish_tags="$script_dir/../scripts/publish-tags.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

remote="$tmp_dir/remote.git"
repo="$tmp_dir/repository"
git init -q --bare "$remote"
git init -q -b master "$repo"
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.invalid
printf 'initial\n' >"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q -u origin master

remote_tag_sha() {
  git --git-dir "$remote" rev-list -n 1 "refs/tags/$1"
}

remote_tag_message() {
  git --git-dir "$remote" for-each-ref --format='%(contents)' "refs/tags/$1"
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'Expected failure: %s\n' "$description" >&2
    exit 1
  fi
}

# Creates the floating tag on the branch tip, accepting a short SHA.
first_sha=$(git -C "$repo" rev-parse HEAD)
short_first_sha=$(git -C "$repo" rev-parse --short HEAD)
output=$(bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$short_first_sha" \
  --floating-tag latest)
[[ "$output" == $'floating_tag=latest\ntarget_sha='"$first_sha" ]]
[[ "$(remote_tag_sha latest)" == "$first_sha" ]]
[[ "$(git --git-dir "$remote" cat-file -t refs/tags/latest)" == tag ]]
[[ "$(remote_tag_message latest)" == "Latest commit on master: ${first_sha}" ]]
[[ "$(git --git-dir "$remote" rev-parse refs/heads/master)" == "$first_sha" ]]
if git -C "$repo" rev-parse --verify "refs/tags/release-floating-${first_sha}" >/dev/null 2>&1; then
  printf 'Local helper tag was not removed\n' >&2
  exit 1
fi

# Rerunning for the same commit is idempotent.
bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$first_sha" \
  --floating-tag latest >/dev/null 2>&1
[[ "$(remote_tag_sha latest)" == "$first_sha" ]]

# A new commit on the branch moves the floating tag forward.
printf 'second\n' >>"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm second
git -C "$repo" push -q origin master
second_sha=$(git -C "$repo" rev-parse HEAD)

bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$second_sha" \
  --floating-tag latest \
  --message 'Custom message' >/dev/null 2>&1
[[ "$(remote_tag_sha latest)" == "$second_sha" ]]
[[ "$(remote_tag_message latest)" == 'Custom message' ]]

# A stale target never moves the floating tag backwards nor touches the branch.
expect_failure 'stale target' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$first_sha" \
  --floating-tag latest
[[ "$(remote_tag_sha latest)" == "$second_sha" ]]
[[ "$(remote_tag_message latest)" == 'Custom message' ]]
[[ "$(git --git-dir "$remote" rev-parse refs/heads/master)" == "$second_sha" ]]

# Immutable version tags stay untouched by later floating tag moves.
bash "$publish_tags" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$second_sha" \
  --version-tag v1.0.0 \
  --floating-tag latest >/dev/null 2>&1
[[ "$(remote_tag_message latest)" == 'Latest release: v1.0.0' ]]

printf 'third\n' >>"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm third
git -C "$repo" push -q origin master
third_sha=$(git -C "$repo" rev-parse HEAD)

bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$third_sha" \
  --floating-tag latest >/dev/null 2>&1
[[ "$(remote_tag_sha latest)" == "$third_sha" ]]
[[ "$(remote_tag_sha v1.0.0)" == "$second_sha" ]]

# Invalid input is rejected without publishing anything.
expect_failure 'version-like floating tag' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$third_sha" \
  --floating-tag v1.0.0
[[ "$(remote_tag_sha v1.0.0)" == "$second_sha" ]]

expect_failure 'prefixed version-like floating tag' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$third_sha" \
  --floating-tag my-app-v2.3.4

expect_failure 'invalid tag name' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$third_sha" \
  --floating-tag 'bad..name'

expect_failure 'unknown commit' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha 0000000000000000000000000000000000000000 \
  --floating-tag latest

expect_failure 'missing floating tag' bash "$move_floating_tag" \
  --repository "$repo" \
  --release-branch master \
  --target-sha "$third_sha"

expect_failure 'missing release branch' bash "$move_floating_tag" \
  --repository "$repo" \
  --target-sha "$third_sha" \
  --floating-tag latest

[[ "$(remote_tag_sha latest)" == "$third_sha" ]]
if git --git-dir "$remote" rev-parse --verify refs/tags/my-app-v2.3.4 >/dev/null 2>&1; then
  printf 'Version-like floating tag was published\n' >&2
  exit 1
fi

printf 'floating tag tests passed\n'
