#!/usr/bin/env sh
# Federate a CI OIDC token to GCP and write an ADC external_account file.
# Used by GitLab CI (and local runs). GitHub uses google-github-actions/auth,
# which produces an equivalent credential. cosign/gcloud then pick up ADC.
#
# Usage (GitLab): eval "$(OIDC_TOKEN="$GCP_ID_TOKEN" ./gcp-federate.sh)"
set -eu
umask 077

: "${GCP_WIF_AUDIENCE:?GCP_WIF_AUDIENCE required}"  # //iam.googleapis.com/projects/.../providers/gitlab
: "${GCP_SIGNER_SA:?GCP_SIGNER_SA required}"        # slsa-provenance-signer@PROJECT.iam.gserviceaccount.com
: "${OIDC_TOKEN:?OIDC_TOKEN required}"

workdir="${RUNNER_TEMP:-${CI_BUILDS_DIR:-/tmp}}"
token_file="$workdir/oidc_token.jwt"
cred_file="$workdir/gcp_adc.json"

printf '%s' "$OIDC_TOKEN" >"$token_file"

cat >"$cred_file" <<EOF
{
  "type": "external_account",
  "audience": "$GCP_WIF_AUDIENCE",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$GCP_SIGNER_SA:generateAccessToken",
  "credential_source": { "file": "$token_file", "format": { "type": "text" } }
}
EOF

echo "export GOOGLE_APPLICATION_CREDENTIALS=$cred_file"
