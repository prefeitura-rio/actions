#!/usr/bin/env sh
# Verify an image's signed CycloneDX SBOM attestation and enforce policy:
# signature valid (by cosign), statement subject == image digest, predicate
# type CycloneDX, and a CycloneDX document that lists at least MIN_COMPONENTS
# components. Optionally saves the verified SBOM to SBOM_FILE so the consumer
# collects exactly what was signed. Requires cosign, jq and base64.
#
# VERIFY_KEY may be a local public-key PEM (offline trust root) or a
# gcpkms:// URI. With private KMS-only signing there is no Rekor entry,
# so tlog verification is skipped by default.
set -eu

: "${IMAGE_DIGEST:?IMAGE_DIGEST required}" # registry/image@sha256:...
: "${VERIFY_KEY:?VERIFY_KEY required}"
ignore_tlog="${IGNORE_TLOG:-true}"
min_components="${MIN_COMPONENTS:-1}"
sbom_file="${SBOM_FILE:-}"

cyclonedx_type="https://cyclonedx.org/bom"

# Only a digest pins the image: a tag can be moved to another image after
# the SBOM was signed.
digest="${IMAGE_DIGEST##*@sha256:}"
if [ "$digest" = "$IMAGE_DIGEST" ] ||
  ! printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "sbom: IMAGE_DIGEST must be <image>@sha256:<64 hex>, got '$IMAGE_DIGEST'" >&2
  exit 2
fi

case "$min_components" in
'' | *[!0-9]* | ??????????*)
  echo "sbom: MIN_COMPONENTS must be a non-negative integer of at most 9 digits, got '$min_components'" >&2
  exit 2
  ;;
esac

att="$(cosign verify-attestation \
  --key "$VERIFY_KEY" \
  --type cyclonedx \
  --insecure-ignore-tlog="$ignore_tlog" \
  "$IMAGE_DIGEST")"

encoded="$(printf '%s' "$att" | jq -rs '.[0].payload // empty')"
if [ -z "$encoded" ]; then
  echo "sbom: no CycloneDX attestation returned for $IMAGE_DIGEST" >&2
  exit 1
fi

if ! statement="$(printf '%s' "$encoded" | base64 -d)" ||
  ! printf '%s' "$statement" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "sbom: attestation payload is not a JSON in-toto statement" >&2
  exit 1
fi

predicate_type="$(printf '%s' "$statement" | jq -r '.predicateType // ""')"
if [ "$predicate_type" != "$cyclonedx_type" ]; then
  echo "sbom: predicate type mismatch: got '$predicate_type'" >&2
  exit 1
fi

if ! printf '%s' "$statement" |
  jq -e --arg digest "$digest" 'any(.subject[]?; .digest.sha256 == $digest)' >/dev/null; then
  echo "sbom: subject mismatch: no subject with digest sha256:$digest" >&2
  exit 1
fi

bom="$(printf '%s' "$statement" | jq -c '.predicate')"
bom_format="$(printf '%s' "$bom" | jq -r 'if type == "object" then .bomFormat // "" else "" end')"
if [ "$bom_format" != "CycloneDX" ]; then
  echo "sbom: predicate is not a CycloneDX document: bomFormat '$bom_format'" >&2
  exit 1
fi

spec_version="$(printf '%s' "$bom" | jq -r '.specVersion // ""')"
if [ -z "$spec_version" ]; then
  echo "sbom: CycloneDX document has no specVersion" >&2
  exit 1
fi

components="$(printf '%s' "$bom" | jq -r '.components // [] | if type == "array" then length else "invalid" end')"
if [ "$components" = invalid ]; then
  echo "sbom: CycloneDX components is not an array" >&2
  exit 1
fi
if [ "$components" -lt "$min_components" ]; then
  echo "sbom: CycloneDX document lists $components components, expected at least $min_components" >&2
  exit 1
fi

if [ -n "$sbom_file" ]; then
  printf '%s\n' "$bom" | jq . >"$sbom_file"
fi

echo "sbom OK: $IMAGE_DIGEST"
echo "  format:     CycloneDX $spec_version"
echo "  components: $components"
if [ -n "$sbom_file" ]; then
  echo "  saved:      $sbom_file"
fi
