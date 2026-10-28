#!/usr/bin/env sh
# Sign a predicate and attach it to the image as an in-toto attestation,
# using a GCP KMS key via cosign. Defaults to SLSA provenance; set
# PREDICATE_TYPE=cyclonedx (or spdxjson) to attest an SBOM instead.
# Requires Google application credentials in the environment (ADC).
set -eu

: "${IMAGE_DIGEST:?IMAGE_DIGEST required}"   # registry/image@sha256:...
: "${KMS_KEY:?KMS_KEY required}"             # gcpkms://projects/.../cryptoKeyVersions/1
: "${PREDICATE_FILE:?PREDICATE_FILE required}"
predicate_type="${PREDICATE_TYPE:-https://slsa.dev/provenance/v1}"
tlog_upload="${TLOG_UPLOAD:-false}"

# Accept either the full gcpkms:// version URI or a bare KMS key id and
# normalize: cosign reads anything without the gcpkms:// scheme as a local
# file, and gcpkms signing needs an explicit crypto key version.
key="$KMS_KEY"
case "$key" in
  gcpkms://*) ;;
  *) key="gcpkms://$key" ;;
esac
case "$key" in
  */cryptoKeyVersions/* | */versions/*) ;;
  *) key="$key/cryptoKeyVersions/${KMS_KEY_VERSION:-1}" ;;
esac

cosign attest --yes \
  --key "$key" \
  --type "$predicate_type" \
  --predicate "$PREDICATE_FILE" \
  --tlog-upload="$tlog_upload" \
  "$IMAGE_DIGEST"
