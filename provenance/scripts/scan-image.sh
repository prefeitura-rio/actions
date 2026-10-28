#!/usr/bin/env bash
# Scan the built image for vulnerabilities with grype and upload to DefectDojo,
# tagged image/container so findings are distinguishable from source-code
# findings uploaded by actions/sast. Mirrors the sast reimport pattern.
# Requires syft, grype, jq, curl and registry pull access for IMAGE_DIGEST.
set -eo pipefail

: "${IMAGE_DIGEST:?IMAGE_DIGEST required}"

touch image-grype.sarif
syft "$IMAGE_DIGEST" -o cyclonedx-json=image-cdx.json
grype sbom:image-cdx.json -o table -o sarif=image-grype.sarif -o json=image-grype.json

if [ -n "${DD_API_TOKEN:-}" ] && [ -n "${DD_URL:-}" ] && [ "${CURRENT_BRANCH:-}" = "${DEFAULT_BRANCH:-}" ]; then
    # Append each SBOM component as an INFO finding so DefectDojo tracks the
    # full image package inventory next to the real grype vulnerabilities.
    jq '
    .vulnerabilities += [
      .components[] | {
        "id": ("INFO-" + .name),
        "source": { "name": "Not-A-Vuln" },
        "ratings": [{ "severity": "info", "method": "other" }],
        "description": "Image package inventory entry.",
        "affects": [{ "ref": (.["bom-ref"] // .purl) }]
      }
    ]' image-cdx.json >image-bom-info.json

    echo "Resolving DefectDojo product..."
    PRODUCT_INFO=$(curl -s -X GET "$DD_URL/api/v2/products/?name=${PRODUCT_NAME}" \
        -H "Authorization: Token $DD_API_TOKEN" | tr -d '\000-\037')
    COUNT=$(echo "$PRODUCT_INFO" | jq '.count')
    if [ "$COUNT" -gt 0 ]; then
        PARAM_TYPE="product_type=$(echo "$PRODUCT_INFO" | jq '.results[0].prod_type')"
    else
        PARAM_TYPE="product_type_name=Uncategorized"
    fi

    dd_reimport() {
        local scan_type="$1" file="$2" title="$3" resp
        resp=$(curl -s -X POST "$DD_URL/api/v2/reimport-scan/" \
            -H "Authorization: Token $DD_API_TOKEN" \
            -H "Content-Type: multipart/form-data" \
            -F "active=true" \
            -F "verified=true" \
            -F "scan_type=$scan_type" \
            -F "product_name=$PRODUCT_NAME" \
            -F "engagement_name=$ENGAGEMENT_NAME" \
            -F "test_title=$title" \
            -F "tags=image" \
            -F "tags=container" \
            -F "file=@$file" \
            -F "$PARAM_TYPE" \
            -F "auto_create_context=true" \
            -F "close_old_findings=true")
        if echo "$resp" | grep -q '"test":'; then
            echo "Reimported: $title"
        else
            echo "Error reimporting '$title' to DefectDojo:" >&2
            echo "$resp" >&2
        fi
    }

    dd_reimport "CycloneDX Scan" image-bom-info.json "Image SBOM (syft)"
    dd_reimport "Anchore Grype" image-grype.json "Image Vulnerabilities (grype)"
fi
