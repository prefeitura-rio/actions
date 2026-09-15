#!/usr/bin/env bash

set -euo pipefail

repository="."
remote="origin"
release_branch=""
target_sha=""
version_tag=""
floating_tag=""
author_name="CI Release Bot"
author_email="ci-release@example.invalid"

usage() {
  cat >&2 <<'EOF'
Usage: publish-tags.sh --release-branch BRANCH --target-sha SHA --version-tag TAG [options]

Options:
  --repository PATH       Git repository path (default: .)
  --remote NAME           Git remote name (default: origin)
  --release-branch BRANCH Branch whose tip must remain target (required)
  --target-sha SHA        Commit to tag (required)
  --version-tag TAG       Immutable version tag (required)
  --floating-tag TAG      Mutable tag to update (optional)
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
    --version-tag)
      version_tag="$2"
      shift 2
      ;;
    --floating-tag)
      floating_tag="$2"
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

if [[ -z "$release_branch" || -z "$target_sha" || -z "$version_tag" ]]; then
  echo "--release-branch, --target-sha, and --version-tag are required." >&2
  usage
  exit 2
fi

if [[ -n "$floating_tag" && "$floating_tag" == "$version_tag" ]]; then
  echo "Floating tag must differ from the immutable version tag." >&2
  exit 1
fi

target_sha=$(git -C "$repository" rev-parse --verify "${target_sha}^{commit}")

version_tag_created=false
floating_tag_created=false
floating_local_tag="release-floating-${target_sha}"
publication_succeeded=false
cleanup_local_tags() {
  if [[ "$publication_succeeded" != true && "$version_tag_created" == true ]]; then
    git -C "$repository" tag -d "$version_tag" >/dev/null 2>&1 || true
  fi
  if [[ "$floating_tag_created" == true ]]; then
    git -C "$repository" tag -d "$floating_local_tag" >/dev/null 2>&1 || true
  fi
}
trap cleanup_local_tags EXIT

if existing_sha=$(git -C "$repository" rev-list -n 1 "$version_tag" 2>/dev/null); then
  if [[ "$existing_sha" != "$target_sha" ]]; then
    echo "Version tag ${version_tag} already points to ${existing_sha}, not ${target_sha}." >&2
    exit 1
  fi
else
  git -C "$repository" \
    -c user.name="$author_name" \
    -c user.email="$author_email" \
    tag -a "$version_tag" "$target_sha" -m "Release ${version_tag}"
  version_tag_created=true
fi

push_refspecs=(
  "${target_sha}:refs/heads/${release_branch}"
  "refs/tags/${version_tag}"
)
if [[ -n "$floating_tag" ]]; then
  git -C "$repository" \
    -c user.name="$author_name" \
    -c user.email="$author_email" \
    tag -a "$floating_local_tag" "$target_sha" \
    -m "Latest release: ${version_tag}"
  floating_tag_created=true
  push_refspecs+=("+refs/tags/${floating_local_tag}:refs/tags/${floating_tag}")
fi

git -C "$repository" push \
  --atomic \
  "--force-with-lease=refs/heads/${release_branch}:${target_sha}" \
  "$remote" \
  "${push_refspecs[@]}" >&2

publication_succeeded=true
git -C "$repository" tag -d "$floating_local_tag" >/dev/null 2>&1 || true
floating_tag_created=false
trap - EXIT

printf 'version_tag=%s\n' "$version_tag"
printf 'floating_tag=%s\n' "$floating_tag"
