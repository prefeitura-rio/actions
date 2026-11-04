#!/usr/bin/env bash
# Portable tests for the SLSA provenance scripts. They need bash, jq and
# base64 only: cosign is replaced by a stub on PATH, so no cloud credential,
# KMS key or registry is involved. Every script runs under `env -i`, so CI
# variables of the runner (GITHUB_ACTIONS, RUNNER_TEMP...) never leak in.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scripts="$script_dir/../scripts"
generate_predicate="$scripts/generate-predicate.sh"
sign_provenance="$scripts/sign-provenance.sh"
verify_provenance="$scripts/verify-provenance.sh"
gcp_federate="$scripts/gcp-federate.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/cosign" <<'STUB'
#!/usr/bin/env sh
# cosign stub: records its arguments, one per line, and replays a canned
# attestation for verify-attestation.
set -eu
: "${COSIGN_LOG:?COSIGN_LOG required}"
printf '%s\n' "$@" >"$COSIGN_LOG"
if [ "${COSIGN_EXIT:-0}" != 0 ]; then
  echo "cosign stub: forced failure" >&2
  exit "$COSIGN_EXIT"
fi
if [ "${1:-}" = verify-attestation ]; then
  cat "${COSIGN_ATTESTATION:?COSIGN_ATTESTATION required}"
fi
STUB
chmod +x "$stub_dir/cosign"

test_path="$stub_dir:$PATH"
out="$tmp_dir/stdout"
err="$tmp_dir/stderr"
cosign_log="$tmp_dir/cosign.log"
status=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [[ -s "$out" ]]; then
    printf -- '--- stdout\n%s\n' "$(<"$out")" >&2
  fi
  if [[ -s "$err" ]]; then
    printf -- '--- stderr\n%s\n' "$(<"$err")" >&2
  fi
  exit 1
}

# run_isolated VAR=value... -- script: runs the script with only the given
# variables (plus PATH and HOME), capturing stdout, stderr and the status.
run_isolated() {
  local assignments=()
  while [[ "$1" != -- ]]; do
    assignments+=("$1")
    shift
  done
  shift
  rm -f "$cosign_log"
  status=0
  env -i PATH="$test_path" HOME="$tmp_dir" COSIGN_LOG="$cosign_log" \
    "${assignments[@]}" "$@" >"$out" 2>"$err" || status=$?
}

assert_status() {
  [[ "$status" == "$1" ]] || fail "$2: expected exit $1, got $status"
}

assert_failed() {
  [[ "$status" != 0 ]] || fail "$1: expected a non-zero exit"
}

assert_stderr_contains() {
  [[ "$(<"$err")" == *"$1"* ]] || fail "$2: stderr does not contain '$1'"
}

assert_stdout_contains() {
  [[ "$(<"$out")" == *"$1"* ]] || fail "$2: stdout does not contain '$1'"
}

assert_stdout_lacks() {
  [[ "$(<"$out")" != *"$1"* ]] || fail "$2: stdout unexpectedly contains '$1'"
}

assert_cosign_args() {
  [[ -f "$cosign_log" ]] || fail "$2: cosign was not called"
  local actual
  actual=$(<"$cosign_log")
  [[ "$actual" == "$1" ]] || fail "$2: unexpected cosign arguments:
$actual
expected:
$1"
}

assert_cosign_not_called() {
  [[ ! -e "$cosign_log" ]] || fail "$1: cosign was called"
}

rfc3339_utc='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# --- generate-predicate.sh ---------------------------------------------------

builder_id='https://github.com/prefeitura-rio/actions/.github/workflows/build-and-release.yml@refs/heads/master'
build_type='https://github.com/prefeitura-rio/actions/build-and-release@v1'

github_env=(
  GITHUB_ACTIONS=true
  GITHUB_SERVER_URL=https://github.com
  GITHUB_REPOSITORY=prefeitura-rio/example
  GITHUB_REF=refs/heads/main
  GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
  GITHUB_RUN_ID=42
  GITHUB_WORKFLOW_REF=prefeitura-rio/example/.github/workflows/ci.yml@refs/heads/main
)

# assert_predicate <file> <platform> <source> <commit> <invocation> <entry> <started>
assert_predicate() {
  local file="$1" context="$2 predicate"
  jq -e \
    --arg builder "$builder_id" \
    --arg build_type "$build_type" \
    --arg platform "$2" \
    --arg source "$3" \
    --arg commit "$4" \
    --arg invocation "$5" \
    --arg entry "$6" \
    --arg started "$7" \
    'del(.runDetails.metadata.finishedOn) == {
      buildDefinition: {
        buildType: $build_type,
        externalParameters: { source: $source, entryPoint: $entry },
        internalParameters: { platform: $platform },
        resolvedDependencies: [ { uri: $source, digest: { gitCommit: $commit } } ]
      },
      runDetails: {
        builder: { id: $builder },
        metadata: { invocationId: $invocation, startedOn: $started }
      }
    }' "$file" >/dev/null || fail "$context: unexpected structure: $(<"$file")"
  local finished
  finished=$(jq -r '.runDetails.metadata.finishedOn' "$file")
  [[ "$finished" =~ $rfc3339_utc ]] || fail "$context: finishedOn '$finished' is not RFC 3339 UTC"
}

run_isolated BUILDER_ID="$builder_id" BUILD_STARTED_ON=2026-01-02T03:04:05Z \
  "${github_env[@]}" -- "$generate_predicate"
assert_status 0 'github predicate'
cp "$out" "$tmp_dir/github-predicate.json"
assert_predicate "$tmp_dir/github-predicate.json" github-actions \
  'git+https://github.com/prefeitura-rio/example@refs/heads/main' \
  0123456789abcdef0123456789abcdef01234567 \
  'https://github.com/prefeitura-rio/example/actions/runs/42/attempts/1' \
  'prefeitura-rio/example/.github/workflows/ci.yml@refs/heads/main' \
  2026-01-02T03:04:05Z

run_isolated BUILDER_ID="$builder_id" GITHUB_RUN_ATTEMPT=3 \
  "${github_env[@]}" -- "$generate_predicate"
assert_status 0 'github predicate with run attempt'
invocation=$(jq -r '.runDetails.metadata.invocationId' "$out")
[[ "$invocation" == 'https://github.com/prefeitura-rio/example/actions/runs/42/attempts/3' ]] ||
  fail "github predicate with run attempt: invocationId '$invocation'"
started=$(jq -r '.runDetails.metadata.startedOn' "$out")
[[ "$started" =~ $rfc3339_utc ]] ||
  fail "github predicate without BUILD_STARTED_ON: startedOn '$started' is not RFC 3339 UTC"

run_isolated BUILDER_ID="$builder_id" BUILD_STARTED_ON=2026-01-02T03:04:05Z \
  GITLAB_CI=true \
  CI_PROJECT_URL=https://gitlab.example.invalid/group/example \
  CI_COMMIT_REF_NAME=main \
  CI_COMMIT_SHA=89abcdef0123456789abcdef0123456789abcdef \
  CI_PIPELINE_URL=https://gitlab.example.invalid/group/example/-/pipelines/7 \
  CI_CONFIG_PATH=.gitlab-ci.yml \
  -- "$generate_predicate"
assert_status 0 'gitlab predicate'
cp "$out" "$tmp_dir/gitlab-predicate.json"
assert_predicate "$tmp_dir/gitlab-predicate.json" gitlab-ci \
  'git+https://gitlab.example.invalid/group/example@main' \
  89abcdef0123456789abcdef0123456789abcdef \
  'https://gitlab.example.invalid/group/example/-/pipelines/7' \
  .gitlab-ci.yml \
  2026-01-02T03:04:05Z

# build-and-release.yml passes an empty BUILDER_ID when job.workflow_ref is
# unavailable and relies on the script failing closed.
run_isolated BUILDER_ID= "${github_env[@]}" -- "$generate_predicate"
assert_failed 'empty BUILDER_ID'
assert_stderr_contains 'BUILDER_ID required' 'empty BUILDER_ID'
assert_stdout_lacks 'buildDefinition' 'empty BUILDER_ID'

run_isolated "${github_env[@]}" -- "$generate_predicate"
assert_failed 'missing BUILDER_ID'
assert_stderr_contains 'BUILDER_ID required' 'missing BUILDER_ID'

run_isolated BUILDER_ID="$builder_id" -- "$generate_predicate"
assert_status 1 'unsupported platform'
assert_stderr_contains 'generate-predicate: unsupported CI platform' 'unsupported platform'
assert_stdout_lacks 'buildDefinition' 'unsupported platform'

# --- sign-provenance.sh ------------------------------------------------------

image_digest='ghcr.io/prefeitura-rio/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
kms_key='projects/p/locations/global/keyRings/r/cryptoKeys/k'
predicate_file="$tmp_dir/github-predicate.json"

expected_sign_args() {
  printf '%s\n' attest --yes --key "$1" --type "$2" --predicate "$predicate_file" \
    "--tlog-upload=$3" "$image_digest"
}

# sign_with_key <KMS_KEY> <expected key> <context> [extra VAR=value...]
sign_with_key() {
  local key="$1" expected="$2" context="$3"
  shift 3
  run_isolated IMAGE_DIGEST="$image_digest" KMS_KEY="$key" \
    PREDICATE_FILE="$predicate_file" "$@" -- "$sign_provenance"
  assert_status 0 "$context"
  assert_cosign_args "$(expected_sign_args "$expected" https://slsa.dev/provenance/v1 false)" "$context"
}

sign_with_key "gcpkms://$kms_key/cryptoKeyVersions/2" \
  "gcpkms://$kms_key/cryptoKeyVersions/2" 'full gcpkms URI'
sign_with_key "$kms_key" "gcpkms://$kms_key/cryptoKeyVersions/1" 'bare key id'
sign_with_key "gcpkms://$kms_key" "gcpkms://$kms_key/cryptoKeyVersions/3" \
  'gcpkms URI without version' KMS_KEY_VERSION=3
sign_with_key "$kms_key/cryptoKeyVersions/4" \
  "gcpkms://$kms_key/cryptoKeyVersions/4" 'bare key id with version'
sign_with_key "gcpkms://$kms_key/versions/5" \
  "gcpkms://$kms_key/versions/5" 'gcpkms URI with short version form'

run_isolated IMAGE_DIGEST="$image_digest" KMS_KEY="$kms_key" \
  PREDICATE_FILE="$predicate_file" PREDICATE_TYPE=cyclonedx TLOG_UPLOAD=true \
  -- "$sign_provenance"
assert_status 0 'SBOM attestation'
assert_cosign_args "$(expected_sign_args "gcpkms://$kms_key/cryptoKeyVersions/1" cyclonedx true)" \
  'SBOM attestation'

sign_env=(IMAGE_DIGEST="$image_digest" KMS_KEY="$kms_key" PREDICATE_FILE="$predicate_file")
for required in IMAGE_DIGEST KMS_KEY PREDICATE_FILE; do
  partial_env=()
  for assignment in "${sign_env[@]}"; do
    [[ "$assignment" == "$required="* ]] || partial_env+=("$assignment")
  done
  run_isolated "${partial_env[@]}" -- "$sign_provenance"
  assert_failed "sign without $required"
  assert_stderr_contains "$required required" "sign without $required"
  assert_cosign_not_called "sign without $required"
done

run_isolated "${sign_env[@]}" COSIGN_EXIT=1 -- "$sign_provenance"
assert_failed 'sign with cosign failure'
assert_stderr_contains 'cosign stub: forced failure' 'sign with cosign failure'

# --- verify-provenance.sh ----------------------------------------------------

verify_key="$tmp_dir/cosign.pub"
printf 'stub public key\n' >"$verify_key"
attestation="$tmp_dir/attestation.json"

# write_attestation <predicate file>: wraps the predicate in an in-toto
# statement and a DSSE envelope, as cosign verify-attestation prints it.
write_attestation() {
  local payload
  payload=$(jq -c --arg digest "${image_digest#*@sha256:}" '{
      _type: "https://in-toto.io/Statement/v1",
      subject: [ { name: "ghcr.io/prefeitura-rio/example", digest: { sha256: $digest } } ],
      predicateType: "https://slsa.dev/provenance/v1",
      predicate: .
    }' "$1" | base64 | tr -d '\n')
  jq -cn --arg payload "$payload" \
    '{ payloadType: "application/vnd.in-toto+json", payload: $payload, signatures: [ { sig: "c3R1Yg==" } ] }' \
    >"$attestation"
}

expected_verify_args() {
  printf '%s\n' verify-attestation --key "$verify_key" --type https://slsa.dev/provenance/v1 \
    "--insecure-ignore-tlog=$1" "$image_digest"
}

source_regex='^git\+https://github\.com/prefeitura-rio/example@'
verify_env=(
  IMAGE_DIGEST="$image_digest"
  VERIFY_KEY="$verify_key"
  EXPECTED_BUILDER_ID="$builder_id"
  COSIGN_ATTESTATION="$attestation"
)

# End to end: the predicate generate-predicate.sh produced is accepted.
write_attestation "$tmp_dir/github-predicate.json"
run_isolated "${verify_env[@]}" EXPECTED_SOURCE_REGEX="$source_regex" -- "$verify_provenance"
assert_status 0 'verify matching provenance'
assert_stdout_contains "provenance OK: $image_digest" 'verify matching provenance'
assert_stdout_contains "builder: $builder_id" 'verify matching provenance'
assert_stdout_contains 'source:  git+https://github.com/prefeitura-rio/example@refs/heads/main' \
  'verify matching provenance'
assert_cosign_args "$(expected_verify_args true)" 'verify matching provenance'

run_isolated "${verify_env[@]}" IGNORE_TLOG=false -- "$verify_provenance"
assert_status 0 'verify with tlog and default source regex'
assert_cosign_args "$(expected_verify_args false)" 'verify with tlog and default source regex'

# Builder mismatch: another builder, and a builder that only extends the
# expected one, are both rejected.
for forged_builder in \
  'https://github.com/attacker/actions/.github/workflows/build-and-release.yml@refs/heads/master' \
  "${builder_id}-evil"; do
  jq --arg builder "$forged_builder" '.runDetails.builder.id = $builder' \
    "$tmp_dir/github-predicate.json" >"$tmp_dir/forged-builder.json"
  write_attestation "$tmp_dir/forged-builder.json"
  run_isolated "${verify_env[@]}" EXPECTED_SOURCE_REGEX="$source_regex" -- "$verify_provenance"
  assert_status 1 "verify builder mismatch ($forged_builder)"
  assert_stderr_contains "provenance: builder mismatch: got '$forged_builder'" \
    "verify builder mismatch ($forged_builder)"
  assert_stdout_lacks 'provenance OK' "verify builder mismatch ($forged_builder)"
done

# Source mismatch: provenance of another repository is rejected.
write_attestation "$tmp_dir/gitlab-predicate.json"
run_isolated "${verify_env[@]}" EXPECTED_SOURCE_REGEX="$source_regex" -- "$verify_provenance"
assert_status 1 'verify source mismatch'
assert_stderr_contains "provenance: source mismatch: got 'git+https://gitlab.example.invalid/group/example@main'" \
  'verify source mismatch'
assert_stdout_lacks 'provenance OK' 'verify source mismatch'

# A failed signature verification stops the script before any policy check.
write_attestation "$tmp_dir/github-predicate.json"
run_isolated "${verify_env[@]}" COSIGN_EXIT=1 -- "$verify_provenance"
assert_failed 'verify with cosign failure'
assert_stderr_contains 'cosign stub: forced failure' 'verify with cosign failure'
assert_stdout_lacks 'provenance OK' 'verify with cosign failure'

for required in IMAGE_DIGEST VERIFY_KEY EXPECTED_BUILDER_ID; do
  partial_env=()
  for assignment in "${verify_env[@]}"; do
    [[ "$assignment" == "$required="* ]] || partial_env+=("$assignment")
  done
  run_isolated "${partial_env[@]}" -- "$verify_provenance"
  assert_failed "verify without $required"
  assert_stderr_contains "$required required" "verify without $required"
  assert_cosign_not_called "verify without $required"
done

# --- gcp-federate.sh ---------------------------------------------------------

federate_dir="$tmp_dir/federate"
mkdir -p "$federate_dir"
audience='//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/pool/providers/gitlab'
signer_sa='slsa-provenance-signer@example-project.iam.gserviceaccount.com'
oidc_token='header.payload.signature'

run_isolated GCP_WIF_AUDIENCE="$audience" GCP_SIGNER_SA="$signer_sa" \
  OIDC_TOKEN="$oidc_token" RUNNER_TEMP="$federate_dir" -- "$gcp_federate"
assert_status 0 'federate'
[[ "$(<"$out")" == "export GOOGLE_APPLICATION_CREDENTIALS=$federate_dir/gcp_adc.json" ]] ||
  fail 'federate: unexpected export line'
[[ "$(<"$federate_dir/oidc_token.jwt")" == "$oidc_token" ]] ||
  fail 'federate: token file does not hold the OIDC token'
jq -e \
  --arg audience "$audience" \
  --arg impersonation "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$signer_sa:generateAccessToken" \
  --arg token_file "$federate_dir/oidc_token.jwt" \
  '. == {
    type: "external_account",
    audience: $audience,
    subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
    token_url: "https://sts.googleapis.com/v1/token",
    service_account_impersonation_url: $impersonation,
    credential_source: { file: $token_file, format: { type: "text" } }
  }' "$federate_dir/gcp_adc.json" >/dev/null ||
  fail "federate: unexpected credential file: $(<"$federate_dir/gcp_adc.json")"
for written in oidc_token.jwt gcp_adc.json; do
  [[ -z "$(find "$federate_dir/$written" -perm -g=r -o -perm -o=r)" ]] ||
    fail "federate: $written is readable by group or others"
done

federate_env=(GCP_WIF_AUDIENCE="$audience" GCP_SIGNER_SA="$signer_sa" OIDC_TOKEN="$oidc_token")
for required in GCP_WIF_AUDIENCE GCP_SIGNER_SA OIDC_TOKEN; do
  partial_env=()
  for assignment in "${federate_env[@]}"; do
    [[ "$assignment" == "$required="* ]] || partial_env+=("$assignment")
  done
  empty_dir="$tmp_dir/federate-without-$required"
  mkdir -p "$empty_dir"
  run_isolated "${partial_env[@]}" RUNNER_TEMP="$empty_dir" -- "$gcp_federate"
  assert_failed "federate without $required"
  assert_stderr_contains "$required required" "federate without $required"
  [[ -z "$(ls -A "$empty_dir")" ]] || fail "federate without $required: files were written"
done

printf 'provenance script tests passed\n'
