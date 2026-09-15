#!/usr/bin/env bash

set -euo pipefail

repository=""
target_sha=""
required_workflows=()

usage() {
  cat >&2 <<'EOF'
Usage: check-workflow-gates.sh --repository OWNER/REPOSITORY --target-sha SHA --required-workflow NAME [...]

Options:
  --repository OWNER/REPOSITORY Repository whose workflow runs are checked (required)
  --target-sha SHA              Full commit SHA being released (required)
  --required-workflow NAME     Workflow that must have passed (repeatable)
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
    --required-workflow)
      required_workflows+=("$2")
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

if [[ -z "$repository" || -z "$target_sha" || "${#required_workflows[@]}" -eq 0 ]]; then
  echo "--repository, --target-sha, and at least one --required-workflow are required." >&2
  usage
  exit 2
fi

if [[ ! "$target_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "--target-sha must be a full 40-character commit SHA." >&2
  exit 1
fi

runs=$(gh api --method GET "repos/${repository}/actions/runs" \
  -f "head_sha=${target_sha}" \
  -f 'event=push' \
  -f 'per_page=100')

workflow_succeeded() {
  local workflow_name="$1"
  jq -e --arg workflow_name "$workflow_name" --arg target_sha "$target_sha" '
    any(.workflow_runs[];
      .name == $workflow_name and
      .head_sha == $target_sha and
      .event == "push" and
      .status == "completed" and
      .conclusion == "success"
    )
  ' <<< "$runs" >/dev/null
}

failed_workflows=()
for workflow_name in "${required_workflows[@]}"; do
  if workflow_succeeded "$workflow_name"; then
    echo "Required workflow succeeded: ${workflow_name}" >&2
  else
    failed_workflows+=("$workflow_name")
  fi
done

if [[ "${#failed_workflows[@]}" -eq 0 ]]; then
  printf 'ready=true\n'
  printf 'reason=all-gates-passed\n'
else
  printf 'ready=false\n'
  printf 'reason=required-gate-missing-or-failed\n'
  printf 'Required workflow missing or failed: %s\n' "${failed_workflows[*]}" >&2
fi
