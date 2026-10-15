# SLSA provenance signing

SLSA Build L3 provenance for container images, signed with a GCP KMS key via
OIDC workload identity federation. Works on GitHub Actions and GitLab CI with
the same scripts, so it survives the GitLab migration. No GitHub-native
provenance, no Sigstore public-good dependency.

## How it reaches L3

- **L1** in-toto SLSA Provenance v1 predicate generated from CI context.
- **L2** signed by an asymmetric KMS key the build steps never hold.
- **L3** signing runs in a separate job, and the signer identity can only be
  assumed by the trusted build workflow (`job_workflow_ref` on GitHub,
  `namespace_path` + protected ref on GitLab). A tenant repo triggers the
  build but cannot forge provenance.

SLSA v1.0 Build track tops out at L3; there is no higher level.

## Components

| File | Role |
|---|---|
| `scripts/generate-predicate.sh` | Build the SLSA v1 predicate (GitHub + GitLab) |
| `scripts/gcp-federate.sh` | OIDC to GCP ADC external_account (GitLab, local) |
| `scripts/sign-provenance.sh` | `cosign attest` with the KMS key (provenance or SBOM) |
| `scripts/generate-sbom.sh` | syft CycloneDX SBOM of the built image |
| `scripts/install-scanners.sh` | Pinned, cosign-verified cosign/syft/grype install |
| `scripts/scan-image.sh` | grype image scan + DefectDojo upload (image-tagged) |
| `scripts/verify-provenance.sh` | Verify signature, subject, builder, source |
| `gitlab/build-sign-release.yml` | GitLab CI/CD component (kaniko build + sign + scan) |

Infrastructure lives in `infra/kms/modules/gcp/provenance.tf` (key, signer SA,
WIF pool, GitHub + GitLab providers).

## One-time setup

Apply the infra, then read the outputs:

```sh
cd infra/kms/units/gcp
terragrunt output -raw provenance_wif_provider_github   # -> PROVENANCE_WIF_PROVIDER
terragrunt output -raw provenance_signer_sa             # -> PROVENANCE_SIGNER_SA
terragrunt output -raw provenance_kms_key_version       # -> PROVENANCE_KMS_KEY
terragrunt output -raw provenance_public_key_pem > cosign.pub   # trust root
```

### GitHub (org variables)

Set these as **organization** Actions variables. Until they exist, the
`provenance` job is skipped and builds are unaffected.

- `PROVENANCE_WIF_PROVIDER`
- `PROVENANCE_SIGNER_SA`
- `PROVENANCE_KMS_KEY`

Consumers already calling `build-and-release.yml` get signing automatically
(`sign` input defaults to `true`). Pass `sign: false` to opt out.

### GitLab

Include the component and pass the WIF audience / signer / key as inputs. See
the header of `gitlab/build-sign-release.yml`. Set `gitlab_issuer_uri` and
`gitlab_namespace_path` in the terraform module to match your instance.

## Verify flow

`scripts/verify-provenance.sh` enforces: valid signature, subject equals the
image digest (both via cosign), expected builder identity, and source repo.

```sh
export IMAGE_DIGEST="ghcr.io/prefeitura-rio/app@sha256:..."
export VERIFY_KEY="cosign.pub"   # offline trust root, or gcpkms:// URI
export EXPECTED_BUILDER_ID="https://github.com/prefeitura-rio/actions/.github/workflows/build-and-release.yml@refs/heads/master"
export EXPECTED_SOURCE_REGEX="git\\+https://github.com/prefeitura-rio/app@"
./scripts/verify-provenance.sh
```

Use it as a release gate, a local admin check, or wire the same cosign check
into a Kyverno/admission policy later. With private KMS-only signing there is
no Rekor entry, so tlog verification is skipped (`IGNORE_TLOG=true`).

## SBOM attestation

The signing job also builds a CycloneDX SBOM of the **image** with syft and
attaches it as a second signed attestation (`--type cyclonedx`). Verify it the
same way as provenance:

```sh
cosign verify-attestation --key cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true "ghcr.io/prefeitura-rio/app@sha256:..."
```

## Image vulnerability scanning and DefectDojo

The `image-scan` job (GitHub) / `provenance:scan` (GitLab) runs grype against
the built image and reimports results to DefectDojo, following the actions/sast
pattern (`reimport-scan`, `auto_create_context`, `close_old_findings`). It runs
only on the default branch.

Code vs image findings are distinguished in the same product/engagement:

| Surface | Source | scan_type | test_title | tags |
|---|---|---|---|---|
| Code | actions/sast (syft/grype on repo tree) | Anchore Grype / CycloneDX Scan | default | `code`, `source` |
| Image | this job (syft/grype on image) | Anchore Grype / CycloneDX Scan | `Image Vulnerabilities (grype)` / `Image SBOM (syft)` | `image`, `container` |

Distinct `test_title` keeps the image tests from overwriting the code tests;
filter by the `code` / `image` tags in the DefectDojo UI.

GitHub requirements for the upload (otherwise the scan runs but does not
upload): org variable `DD_URL`, and the caller passes `DD_API_TOKEN` plus
`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` (DefectDojo is reached over Tailscale)
via `secrets: inherit`, and sets `ts_tags`. GitLab reads `DD_URL` and
`DD_API_TOKEN` from CI/CD variables.

## Rotation

The key has no automatic rotation: cosign pins one key version. To rotate,
create a new KMS key version, update `PROVENANCE_KMS_KEY` (version N) and the
distributed `cosign.pub`, then re-sign current images if needed.

## Enabling transparency later

Private KMS-only today. To add tamper-evidence without running Rekor, set an
RFC3161 timestamp authority in `sign-provenance.sh` (cosign
`--timestamp-server-url`). To use a log, set `TLOG_UPLOAD=true` and point
cosign at a Rekor instance; verifiers drop `IGNORE_TLOG`.
