#!/usr/bin/env sh
# Decide whether a GitHub build ran on an isolated, ephemeral runner, the
# condition for signing SLSA L3 provenance. Prints `true` or `false` on
# stdout (and the reason on stderr when false); fails only on missing input.
#
# RUNS_ON is the runner label the caller passed to build-and-release.yml (a
# workflow input, so the runner cannot change it) and must be a standard
# GitHub-hosted label. BUILD_RUNNER_ENVIRONMENT is runner.environment of the
# build job and must be `github-hosted`. A self-hosted runner is chosen and
# controlled by the caller, can persist state between jobs and could build
# something other than the source, so its builds are not signed.
set -eu

: "${RUNS_ON?RUNS_ON required}"
: "${BUILD_RUNNER_ENVIRONMENT?BUILD_RUNNER_ENVIRONMENT required}"

case "$RUNS_ON" in
ubuntu-latest | ubuntu-24.04 | ubuntu-22.04 | ubuntu-24.04-arm | ubuntu-22.04-arm)
  hosted_label=true
  ;;
*)
  hosted_label=false
  ;;
esac

if [ "$hosted_label" = true ] && [ "$BUILD_RUNNER_ENVIRONMENT" = github-hosted ]; then
  echo true
  exit 0
fi

echo "provenance: not signing: the build ran on runs_on '$RUNS_ON' (runner environment '$BUILD_RUNNER_ENVIRONMENT'); SLSA L3 provenance is signed only for builds on a standard GitHub-hosted Ubuntu runner" >&2
echo false
