#!/usr/bin/env bash

set -euo pipefail

repository="."
remote="origin"
release_branch=""
target_sha=""

usage() {
  cat >&2 <<'EOF'
Usage: validate-target.sh --release-branch BRANCH --target-sha SHA [options]

Options:
  --repository PATH       Git repository path (default: .)
  --remote NAME           Git remote name (default: origin)
  --release-branch BRANCH Branch whose tip must match the target (required)
  --target-sha SHA        Commit being released (required)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="$2"
      shift 2
      ;;
    --remote)
      remote="$2"
      shift 2
      ;;
    --release-branch)
      release_branch="$2"
      shift 2
      ;;
    --target-sha)
      target_sha="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$release_branch" || -z "$target_sha" ]]; then
  echo "--release-branch and --target-sha are required." >&2
  usage
  exit 2
fi

target_sha=$(git -C "$repository" rev-parse --verify "${target_sha}^{commit}")

branch_ref=$(git -C "$repository" ls-remote "$remote" "refs/heads/${release_branch}")
branch_sha="${branch_ref%%[[:space:]]*}"

if [[ -z "$branch_sha" ]]; then
  echo "Release branch '${release_branch}' was not found on remote '${remote}'." >&2
  exit 1
fi

if [[ "$branch_sha" != "$target_sha" ]]; then
  echo "Target ${target_sha} is no longer the tip of ${release_branch}; skipping release." >&2
  printf 'skip=true\n'
  printf 'reason=stale-target\n'
  exit 0
fi

printf 'skip=false\n'
printf 'branch_sha=%s\n' "$branch_sha"
