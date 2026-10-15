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

cosign attest --yes \
  --key "$KMS_KEY" \
  --type "$predicate_type" \
  --predicate "$PREDICATE_FILE" \
  --tlog-upload="$tlog_upload" \
  "$IMAGE_DIGEST"
