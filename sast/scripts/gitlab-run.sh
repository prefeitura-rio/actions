#!/usr/bin/env bash
# GitLab CI entrypoint for the SAST pipeline.
#
# The per-tool scripts in this directory are shared verbatim with the GitHub
# composite action (sast/action.yml): they speak the GitHub step-runner
# "contract" -- writing to $GITHUB_ENV / $GITHUB_OUTPUT / $GITHUB_PATH /
# $GITHUB_STEP_SUMMARY files, reading github.* context from env, and locating
# bundled assets under $GITHUB_ACTION_PATH. This script emulates that contract
# inside a single GitLab job so those scripts run unchanged, and drives them in
# the same order as action.yml, mapping GitLab predefined variables to the
# context the scripts expect.
set -eo pipefail

# Minimal CI images (e.g. debian:*-slim) default to the C/POSIX locale, under
# which the Python-based scanners (opengrep, checkov) read their own rule/config
# files as ASCII and crash on any UTF-8 byte (UnicodeDecodeError). GitHub's
# ubuntu runners are UTF-8 already; force it here so the scanners work anywhere.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONUTF8="${PYTHONUTF8:-1}"

# --- locate the action root (this file lives at <root>/scripts/gitlab-run.sh) ---
GITHUB_ACTION_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GITHUB_ACTION_PATH
SCRIPTS="$GITHUB_ACTION_PATH/scripts"
# The tailscale / java-setup / sonarqube concerns are decoupled into their own
# reusable components under <repo>/templates/. Locate their scripts here so the
# orchestrator can drive them in-sequence; override to relocate them.
REPO_ROOT="$(cd "$GITHUB_ACTION_PATH/.." && pwd)"
SETUP_JAVA_SCRIPT="${SETUP_JAVA_SCRIPT:-$REPO_ROOT/templates/java-setup/setup-java.sh}"
RUN_SONARQUBE_SCRIPT="${RUN_SONARQUBE_SCRIPT:-$REPO_ROOT/templates/sonarqube/run-sonarqube.sh}"

# --- GitHub step-runner compatibility files ---
_shim_dir="$(mktemp -d)"
export GITHUB_ENV="$_shim_dir/github_env"
export GITHUB_OUTPUT="$_shim_dir/github_output"
export GITHUB_PATH="$_shim_dir/github_path"
export GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-${CI_PROJECT_DIR:-$PWD}/sast-summary.md}"
: >"$GITHUB_ENV"
: >"$GITHUB_OUTPUT"
: >"$GITHUB_PATH"
: >"$GITHUB_STEP_SUMMARY"

# Propagate everything a step wrote to $GITHUB_ENV / $GITHUB_PATH into this shell,
# exactly like the GitHub runner does between steps, then reset those files.
load_env() {
  if [ -s "$GITHUB_ENV" ]; then
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      export "${_line?}"
    done <"$GITHUB_ENV"
    : >"$GITHUB_ENV"
  fi
  if [ -s "$GITHUB_PATH" ]; then
    while IFS= read -r _dir; do
      [ -n "$_dir" ] && PATH="$_dir:$PATH"
    done <"$GITHUB_PATH"
    export PATH
    : >"$GITHUB_PATH"
  fi
}

read_output() { grep -E "^$1=" "$GITHUB_OUTPUT" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
clear_output() { : >"$GITHUB_OUTPUT"; }

# --- map GitLab predefined variables -> the github.* context the scripts read ---
export CURRENT_BRANCH="${CI_COMMIT_REF_NAME:-}"
export DEFAULT_BRANCH="${CI_DEFAULT_BRANCH:-}"
export PRODUCT_NAME="${CI_PROJECT_PATH:-}"
export PROJECT_KEY="repo:${CI_PROJECT_ID:-}"
export ENGAGEMENT_NAME="${OVERRIDE_BRANCH:-${CI_COMMIT_REF_NAME:-}}"
export SONAR_HOST_URL_PUBLIC="${SONAR_HOST_URL:-}"
if [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ]; then
  export BRANCH_KEY="pullRequest"
  export BRANCH_VALUE="${CI_MERGE_REQUEST_IID:-}"
else
  export BRANCH_KEY="branch"
  export BRANCH_VALUE="${OVERRIDE_BRANCH:-${CI_COMMIT_REF_NAME:-}}"
fi

# --- knobs (mirror action.yml input defaults); override via CI/CD variables ---
export ENABLE_CHECKOV="${ENABLE_CHECKOV:-true}"
export CHECKOV_VERSION="${CHECKOV_VERSION:-3.3.8}"
export CHECKOV_OPTS="${CHECKOV_OPTS:-}"
export IGNORE_TYPE="${IGNORE_TYPE:-sonarqube}"
export ENABLE_CLIPPY="${ENABLE_CLIPPY:-false}"
export WAIT_PIPELINE="${WAIT_PIPELINE:-true}"
export SONARQUBE_OPTS="${SONARQUBE_OPTS:-}"
export BREAK_ON="${BREAK_ON:-HIGH}"
export OVERRIDE_BRANCH="${OVERRIDE_BRANCH:-}"
export SONAR_HOST_URL="${SONAR_HOST_URL:-}"
export SONAR_TOKEN="${SONAR_TOKEN:-}"
export DD_URL="${DD_URL:-}"
export DD_API_TOKEN="${DD_API_TOKEN:-}"

# --- continue collecting reports without masking failed steps ---------------
# GitHub's `if: always()` runs later steps but preserves earlier failures.
# Likewise, finish all scanners and the summary, then fail if any required step
# failed even when the summary's quality gate passed.
FAILED_STEPS=()
run() { # run <label> <script>  (script = bare name under $SCRIPTS, or an absolute path)
  local label="$1" script="$2" path
  case "$script" in
    /*) path="$script" ;;
    *) path="$SCRIPTS/$script" ;;
  esac
  echo "----- SAST: ${label} -----"
  if bash "$path"; then
    load_env
  else
    local rc=$?
    echo "::warning:: SAST step '${label}' failed (exit ${rc}); continuing."
    FAILED_STEPS+=("$label")
    load_env
  fi
}

# 1-2. language detection (always succeed; they only echo found=true|false)
run "Detect Rust" detect-rust.sh
RUST_FOUND="$(read_output found)"; clear_output
run "Detect Java" detect-java.sh
JAVA_FOUND="$(read_output found)"; clear_output

# 3. Rust toolchain (only for Rust repos)
if [ "$RUST_FOUND" = "true" ]; then
  run "Install Rust toolchain" install-rust.sh
fi

# 4-8. tool provisioning + scanners
run "Prepare tool cache" prepare-tool-cache.sh; clear_output
run "Install scanner tools" install-tools.sh
run "Normalize ignore files" normalize-ignores.sh
run "Run opengrep" run-opengrep.sh
run "Run vulnerability scan & SBOM" run-vulnerability-scan.sh
run "Run checkov (IaC)" run-checkov.sh

# 9. Java build (only for Java repos) -- needed before Sonar for java.binaries
if [ "$JAVA_FOUND" = "true" ]; then
  run "Set up Java (Temurin) + Maven" "$SETUP_JAVA_SCRIPT"
  echo "----- SAST: Build classes (mvn clean compile) -----"
  if mvn clean compile; then :; else
    echo "::warning:: mvn clean compile failed; continuing."
    FAILED_STEPS+=("Build classes")
  fi
fi

# 10. SonarQube (only when configured)
if [ -n "$SONAR_HOST_URL" ] && [ -n "$SONAR_TOKEN" ]; then
  export SAST_JAVA_FOUND="$JAVA_FOUND"
  run "SonarQube scan" "$RUN_SONARQUBE_SCRIPT"
else
  echo "----- SAST: SonarQube skipped (SONAR_HOST_URL / SONAR_TOKEN not set) -----"
fi

# 11-12. Sonar task id + quality-gate result file (continue-on-error in the action)
run "Find Sonar task ID" find-sonar-task-id.sh
SONAR_TASK_ID="$(read_output sonar_task_id)"
export SONAR_TASK_ID
clear_output
echo "----- SAST: Get Sonar analysis result -----"
bash "$SCRIPTS/get-sonar-result.sh" || echo "::warning:: get Sonar analysis result failed (non-fatal)."

# 13. Summary + quality gate. Always print the summary to the job log (GitLab has
# no step-summary UI) and preserve summary.sh's exit code as the job result.
echo "----- SAST: Summary -----"
set +e
bash "$SCRIPTS/summary.sh"
SUMMARY_RC=$?
set -e

echo "==================== SAST SUMMARY ===================="
cat "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
echo "====================================================="

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  echo "::error:: SAST steps that reported failures: ${FAILED_STEPS[*]}"
  if [ "$SUMMARY_RC" -eq 0 ]; then SUMMARY_RC=1; fi
fi

rm -rf "$_shim_dir"
exit "$SUMMARY_RC"
