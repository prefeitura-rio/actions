#!/usr/bin/env sh
# Verify an image's SLSA provenance attestation and enforce policy:
# signature valid, subject == image digest (both by cosign), expected
# builder identity, and source repository. Requires cosign and jq.
#
# VERIFY_KEY may be a local public-key PEM (offline trust root) or a
# gcpkms:// URI. With private KMS-only signing there is no Rekor entry,
# so tlog verification is skipped by default.
set -eu

: "${IMAGE_DIGEST:?IMAGE_DIGEST required}"
: "${VERIFY_KEY:?VERIFY_KEY required}"
: "${EXPECTED_BUILDER_ID:?EXPECTED_BUILDER_ID required}"
expected_source_regex="${EXPECTED_SOURCE_REGEX:-.*}"
ignore_tlog="${IGNORE_TLOG:-true}"

att="$(cosign verify-attestation \
  --key "$VERIFY_KEY" \
  --type "https://slsa.dev/provenance/v1" \
  --insecure-ignore-tlog="$ignore_tlog" \
  "$IMAGE_DIGEST")"

payload="$(printf '%s' "$att" | jq -rs '.[0].payload' | base64 -d)"

builder="$(printf '%s' "$payload" | jq -r '.predicate.runDetails.builder.id')"
source="$(printf '%s' "$payload" | jq -r '.predicate.buildDefinition.resolvedDependencies[0].uri')"

if [ "$builder" != "$EXPECTED_BUILDER_ID" ]; then
  echo "provenance: builder mismatch: got '$builder'" >&2
  exit 1
fi

if ! printf '%s' "$source" | grep -Eq "$expected_source_regex"; then
  echo "provenance: source mismatch: got '$source'" >&2
  exit 1
fi

echo "provenance OK: $IMAGE_DIGEST"
echo "  builder: $builder"
echo "  source:  $source"
