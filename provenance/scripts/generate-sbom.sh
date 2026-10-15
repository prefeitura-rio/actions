#!/usr/bin/env sh
# Generate a CycloneDX SBOM of the built image with syft. Describes the
# image contents (OS + app packages), not the source tree. Requires syft
# and registry pull access for IMAGE_DIGEST.
set -eu

: "${IMAGE_DIGEST:?IMAGE_DIGEST required}"   # registry/image@sha256:...
out="${SBOM_FILE:-image-sbom.cdx.json}"

syft "$IMAGE_DIGEST" -o cyclonedx-json="$out"
echo "$out"
