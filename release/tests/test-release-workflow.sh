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

# --- credentials -----------------------------------------------------------

job_environment=$(yq '.jobs.release.environment' "$workflow")
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell variable
[[ "$job_environment" == '${{ inputs.environment }}' ]] || fail "the release job must run in the environment given by inputs.environment"
[[ "$(yq '.jobs.release.env' "$workflow")" == null ]] || fail "the release job must not export secrets to every step through env:"
[[ "$(yq '.jobs.release.steps[0].id' "$workflow")" == credentials ]] || fail "the credentials check must be the first step, before any checkout"

# The private key may only be read by the check and by the step that mints the token.
readers=$(yq '[.jobs.release.steps[] | select((. | tostring) | contains("secrets.QUALITY_GATE_RELEASE_APP_PRIVATE_KEY")) | .name] | join(",")' "$workflow")
[[ "$readers" == "Check the release App credentials,Create release App token" ]] || fail "the private key is read by: $readers"

# Interpolating a workflow input into a script is a shell injection.
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell variable
[[ "$(yq '.jobs.release.steps[0].run' "$workflow")" != *'${{'* ]] || fail "the credentials check must receive values through env:, not interpolation"

# Run the real check script with every combination of credentials.
check_script=$(yq '.jobs.release.steps[0].run' "$workflow")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
check() {
  local expectation="$1" app_id="$2" key="$3" environment="$4" label="$5"
  local output="$scratch/output"
  : > "$output"
  local status=0
  RELEASE_APP_ID="$app_id" RELEASE_APP_PRIVATE_KEY="$key" ENVIRONMENT_NAME="$environment" \
    GITHUB_OUTPUT="$output" bash -c "$check_script" >"$scratch/log" 2>&1 || status=$?
  case "$expectation" in
    configured) [[ $status -eq 0 && "$(cat "$output")" == configured=true ]] || fail "$label: expected configured=true, got status $status and '$(cat "$output")'" ;;
    unconfigured) [[ $status -eq 0 && "$(cat "$output")" == configured=false ]] || fail "$label: expected configured=false, got status $status and '$(cat "$output")'" ;;
    error) [[ $status -ne 0 && ! -s "$output" ]] || fail "$label: expected a failure, got status $status and '$(cat "$output")'" ;;
  esac
}
check configured 123 key "" "both set"
check configured 123 key quality-gate-release "both set in an environment"
check unconfigured "" "" "" "none set, no environment (callers without the App keep using GITHUB_TOKEN)"
check error "" "" quality-gate-release "none set in an environment"
check error 123 "" "" "only the id"
check error "" key "" "only the key"
check error 123 "" quality-gate-release "only the id in an environment"
check error "" key quality-gate-release "only the key in an environment"
message=$(RELEASE_APP_ID="" RELEASE_APP_PRIVATE_KEY="" ENVIRONMENT_NAME=quality-gate-release \
  GITHUB_OUTPUT="$scratch/output" bash -c "$check_script" 2>&1 || true)
[[ "$message" == *"environment 'quality-gate-release'"* ]] || fail "the failure for an empty environment must name the environment, got: $message"
[[ "$message" == *"forward them by name"* ]] || fail "the failure must tell the caller to forward the secrets by name"

if ((failures > 0)); then
  exit 1
fi
echo "release.yml contract ok"
