#!/usr/bin/env bash
# GitLab replacement for the GitHub SonarSource/sonarqube-scan-action step.
# Provisions the sonar-scanner CLI (bundled JRE, so no separate Java needed for
# non-Java repos) and runs it with the same -D arguments the action passed,
# mapped from GitLab predefined variables.
#
# Reads: SONAR_HOST_URL, SONAR_TOKEN (required), plus PRODUCT_NAME, CI_PROJECT_ID,
#   WAIT_PIPELINE, ENABLE_CLIPPY, SONARQUBE_OPTS, OVERRIDE_BRANCH, SAST_JAVA_FOUND,
#   SONAR_BRANCH_ANALYSIS, and the CI_MERGE_REQUEST_* / CI_COMMIT_REF_NAME context.
# Optional: SONAR_SCANNER_VERSION (default below), TOOL_DIR (install location).
set -eo pipefail

: "${SONAR_HOST_URL:?SONAR_HOST_URL is required}"
: "${SONAR_TOKEN:?SONAR_TOKEN is required}"

SONAR_SCANNER_VERSION="${SONAR_SCANNER_VERSION:-6.2.1.4610}"
DEST="${TOOL_DIR:-$HOME/.sast-tools}"
SCANNER_DIR="$DEST/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64"

if [ ! -x "$SCANNER_DIR/bin/sonar-scanner" ]; then
  echo "run-sonarqube: installing sonar-scanner ${SONAR_SCANNER_VERSION}..."
  tmp="$(mktemp -d)"
  curl -sfL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o "$tmp/scanner.zip"
  unzip -q "$tmp/scanner.zip" -d "$DEST"
  rm -rf "$tmp"
fi
export PATH="$SCANNER_DIR/bin:$PATH"

args=(
  "-Dsonar.projectName=${PRODUCT_NAME:-${CI_PROJECT_PATH:-${CI_PROJECT_NAME:-repo:${CI_PROJECT_ID}}}}"
  "-Dsonar.projectKey=repo:${CI_PROJECT_ID}"
  "-Dsonar.qualitygate.wait=${WAIT_PIPELINE:-true}"
  "-Dsonar.rust.clippy.enabled=${ENABLE_CLIPPY:-false}"
)

# A standalone scan need not have run any of the SAST report producers.
sarif_reports=""
for report in grype-results.sarif opengrep-sarif.sarif checkov-sarif.sarif; do
  if [ -f "$report" ]; then
    sarif_reports="${sarif_reports:+$sarif_reports,}$report"
  fi
done
if [ -n "$sarif_reports" ]; then
  args+=("-Dsonar.sarifReportPaths=$sarif_reports")
fi

# Community supports only main-branch analysis. Opt out explicitly there; keep
# branch and MR analysis enabled by default for servers with that capability.
if [ "${SONAR_BRANCH_ANALYSIS:-true}" != "false" ]; then
  if [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ]; then
    args+=(
      "-Dsonar.pullrequest.key=${CI_MERGE_REQUEST_IID}"
      "-Dsonar.pullrequest.branch=${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME}"
      "-Dsonar.pullrequest.base=${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
    )
  else
    args+=("-Dsonar.branch.name=${OVERRIDE_BRANCH:-$CI_COMMIT_REF_NAME}")
  fi
fi

if [ "${SAST_JAVA_FOUND:-false}" = "true" ]; then
  args+=("-Dsonar.java.binaries=**/target/classes")
fi

# SONARQUBE_OPTS is intentionally word-split into separate -D args (as in the action).
# shellcheck disable=SC2206
[ -n "${SONARQUBE_OPTS:-}" ] && args+=($SONARQUBE_OPTS)

export SONAR_HOST_URL SONAR_TOKEN
echo "run-sonarqube: sonar-scanner ${args[*]}"
sonar-scanner "${args[@]}"
