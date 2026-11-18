#!/usr/bin/env bash
# Structural contract of .github/workflows/release.yml. The workflow is not run
# by the other release tests, so the order of its steps is checked here.
# Needs mikefarah's yq (preinstalled on GitHub-hosted runners).
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workflow="${RELEASE_WORKFLOW:-$script_dir/../../.github/workflows/release.yml}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required to run this test." >&2
  exit 2
fi

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

steps=$(yq '.jobs.release.steps | length' "$workflow")
authenticate=-1
token=-1
declare -a remote_users=()

for ((i = 0; i < steps; i++)); do
  name=$(yq ".jobs.release.steps[$i].name" "$workflow")
  uses=$(yq ".jobs.release.steps[$i].uses // \"\"" "$workflow")
  run=$(yq ".jobs.release.steps[$i].run // \"\"" "$workflow")

  if [[ "$uses" == actions/checkout@* ]]; then
    persist=$(yq ".jobs.release.steps[$i].with.persist-credentials" "$workflow")
    [[ "$persist" == false ]] || fail "checkout step '$name' must set persist-credentials: false (a persisted GITHUB_TOKEN overrides the App token)"
  fi
  [[ "$name" == "Create release App token" ]] && token=$i
  [[ "$name" == "Authenticate the target remote" ]] && authenticate=$i
  # Every step that runs a toolkit script talks to the remote.
  if [[ "$run" == *release-toolkit/release/scripts/* ]]; then
    remote_users+=("$i:$name")
  fi
done

((token >= 0)) || fail "the release App token step is missing"
((authenticate >= 0)) || fail "the step that puts the token in the target remote is missing"
((token < authenticate)) || fail "the remote is authenticated before the App token exists"

if ((${#remote_users[@]} == 0)); then
  fail "no step runs a toolkit script"
fi
for entry in "${remote_users[@]}"; do
  index=${entry%%:*}
  ((index > authenticate)) || fail "step '${entry#*:}' reaches the remote before it is authenticated; a private repository would fail"
done

if ((failures > 0)); then
  exit 1
fi
echo "release.yml contract ok"
