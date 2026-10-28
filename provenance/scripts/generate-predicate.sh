#!/usr/bin/env sh
# Emit an in-toto SLSA Provenance v1 predicate for the built image.
# Portable across GitHub Actions and GitLab CI. Requires jq.
# cosign wraps this predicate into the signed statement, so only the
# predicate body is printed to stdout.
set -eu

: "${BUILDER_ID:?BUILDER_ID required}"

build_started="${BUILD_STARTED_ON:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
build_finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  source_uri="git+${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}@${GITHUB_REF}"
  source_commit="${GITHUB_SHA}"
  invocation_id="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT:-1}"
  entry_point="${GITHUB_WORKFLOW_REF}"
  platform="github-actions"
elif [ "${GITLAB_CI:-}" = "true" ]; then
  source_uri="git+${CI_PROJECT_URL}@${CI_COMMIT_REF_NAME}"
  source_commit="${CI_COMMIT_SHA}"
  invocation_id="${CI_PIPELINE_URL}"
  entry_point="${CI_CONFIG_PATH}"
  platform="gitlab-ci"
else
  echo "generate-predicate: unsupported CI platform" >&2
  exit 1
fi

jq -n \
  --arg builder_id "$BUILDER_ID" \
  --arg platform "$platform" \
  --arg source_uri "$source_uri" \
  --arg source_commit "$source_commit" \
  --arg invocation_id "$invocation_id" \
  --arg entry_point "$entry_point" \
  --arg started "$build_started" \
  --arg finished "$build_finished" \
  '{
    buildDefinition: {
      buildType: "https://github.com/prefeitura-rio/actions/build-and-release@v1",
      externalParameters: { source: $source_uri, entryPoint: $entry_point },
      internalParameters: { platform: $platform },
      resolvedDependencies: [
        { uri: $source_uri, digest: { gitCommit: $source_commit } }
      ]
    },
    runDetails: {
      builder: { id: $builder_id },
      metadata: {
        invocationId: $invocation_id,
        startedOn: $started,
        finishedOn: $finished
      }
    }
  }'
