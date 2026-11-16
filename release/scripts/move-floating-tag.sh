#!/usr/bin/env bash

set -euo pipefail

repository="."
remote="origin"
release_branch=""
target_sha=""
floating_tag=""
message=""
author_name="CI Release Bot"
author_email="ci-release@example.invalid"

usage() {
  cat >&2 <<'EOF'
Usage: move-floating-tag.sh --release-branch BRANCH --target-sha SHA --floating-tag TAG [options]

Options:
  --repository PATH       Git repository path (default: .)
  --remote NAME           Git remote name (default: origin)
  --release-branch BRANCH Branch whose tip must remain target (required)
  --target-sha SHA        Commit the floating tag must point to (required)
  --floating-tag TAG      Mutable tag to create or move (required)
  --message TEXT          Annotated tag message (default: Latest commit on BRANCH: SHA)
  --author-name NAME      Tag author name (default: CI Release Bot)
  --author-email EMAIL    Tag author email (default: ci-release@example.invalid)
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
    --floating-tag)
      floating_tag="$2"
      shift 2
      ;;
    --message)
      message="$2"
      shift 2
      ;;
    --author-name)
      author_name="$2"
      shift 2
      ;;
    --author-email)
      author_email="$2"
      shift 2
      ;;
    -h | --help)
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

if [[ -z "$release_branch" || -z "$target_sha" || -z "$floating_tag" ]]; then
  echo "--release-branch, --target-sha, and --floating-tag are required." >&2
  usage
  exit 2
fi

if ! git check-ref-format "refs/tags/${floating_tag}"; then
  echo "Invalid floating tag name '${floating_tag}'." >&2
  exit 1
fi

# Immutable version tags (v1.2.3, my-app-v1.2.3) must never be moved.
if [[ "$floating_tag" =~ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Floating tag '${floating_tag}' looks like an immutable version tag." >&2
  exit 1
fi

target_sha=$(git -C "$repository" rev-parse --verify "${target_sha}^{commit}")

if [[ -z "$message" ]]; then
  message="Latest commit on ${release_branch}: ${target_sha}"
fi

floating_local_tag="release-floating-${target_sha}"
floating_tag_created=false
cleanup_local_tag() {
  if [[ "$floating_tag_created" == true ]]; then
    git -C "$repository" tag -d "$floating_local_tag" >/dev/null 2>&1 || true
  fi
}
trap cleanup_local_tag EXIT

git -C "$repository" \
  -c user.name="$author_name" \
  -c user.email="$author_email" \
  tag -f -a "$floating_local_tag" "$target_sha" -m "$message" >/dev/null
floating_tag_created=true

# The branch refspec is a no-op while the branch tip is still target. If the
# branch moved, the lease rejects the push and --atomic keeps the tag where it
# was, so a stale run never moves the floating tag backwards.
git -C "$repository" push \
  --atomic \
  "--force-with-lease=refs/heads/${release_branch}:${target_sha}" \
  "$remote" \
  "${target_sha}:refs/heads/${release_branch}" \
  "+refs/tags/${floating_local_tag}:refs/tags/${floating_tag}" >&2

printf 'floating_tag=%s\n' "$floating_tag"
printf 'target_sha=%s\n' "$target_sha"
