#!/usr/bin/env bash

set -euo pipefail

repository="."
target_sha=""
initial_version="1.0.0"
bump="patch"
tag_prefix="v"

usage() {
  cat >&2 <<'EOF'
Usage: calculate-version.sh --target-sha SHA [options]

Options:
  --repository PATH       Git repository path (default: .)
  --target-sha SHA        Commit that will be released (required)
  --initial-version VER   First version when no stable tag exists (default: 1.0.0)
  --bump TYPE              major, minor, or patch (default: patch)
  --tag-prefix PREFIX      Stable tag prefix (default: v)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="$2"
      shift 2
      ;;
    --target-sha)
      target_sha="$2"
      shift 2
      ;;
    --initial-version)
      initial_version="$2"
      shift 2
      ;;
    --bump)
      bump="$2"
      shift 2
      ;;
    --tag-prefix)
      tag_prefix="$2"
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

if [[ -z "$target_sha" ]]; then
  echo "--target-sha is required." >&2
  usage
  exit 2
fi

if [[ ! "$initial_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid initial version '${initial_version}'. Expected MAJOR.MINOR.PATCH." >&2
  exit 1
fi

case "$bump" in
  major|minor|patch) ;;
  *)
    echo "Invalid bump '${bump}'. Expected major, minor, or patch." >&2
    exit 1
    ;;
esac

target_sha=$(git -C "$repository" rev-parse --verify "${target_sha}^{commit}")

is_stable_tag() {
  local tag="$1"
  local version="${tag#"$tag_prefix"}"
  [[ "$tag" == "$tag_prefix"* ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

stable_tags=""
while IFS= read -r tag; do
  if is_stable_tag "$tag"; then
    stable_tags+="${tag}"$'\n'
  fi
done < <(git -C "$repository" tag --list "${tag_prefix}*")

latest_tag=$(printf '%s' "$stable_tags" | sort -V | tail -n 1)

existing_tags=""
while IFS= read -r tag; do
  if is_stable_tag "$tag"; then
    existing_tags+="${tag}"$'\n'
  fi
done < <(git -C "$repository" tag --points-at "$target_sha")

existing_tag=$(printf '%s' "$existing_tags" | sort -V | tail -n 1)

if [[ -n "$existing_tag" ]]; then
  version="${existing_tag#"$tag_prefix"}"
  version_tag="$existing_tag"
  echo "Reusing existing stable tag ${version_tag}." >&2
elif [[ -z "$latest_tag" ]]; then
  version="$initial_version"
  version_tag="${tag_prefix}${version}"
else
  base_version="${latest_tag#"$tag_prefix"}"
  IFS=. read -r major minor patch <<< "$base_version"

  case "$bump" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="${major}.$((minor + 1)).0" ;;
    patch) version="${major}.${minor}.$((patch + 1))" ;;
  esac

  version_tag="${tag_prefix}${version}"
fi

if existing_sha=$(git -C "$repository" rev-list -n 1 "$version_tag" 2>/dev/null); then
  if [[ "$existing_sha" != "$target_sha" ]]; then
    echo "Version tag ${version_tag} already points to ${existing_sha}, not ${target_sha}." >&2
    exit 1
  fi
fi

printf 'version=%s\n' "$version"
printf 'version_tag=%s\n' "$version_tag"
printf 'latest_tag=%s\n' "$latest_tag"
