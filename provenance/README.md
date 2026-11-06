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
- **Isolated build** (GitHub): the build itself must run on an ephemeral
  GitHub-hosted runner. `build-and-release.yml` signs only when `runs_on` is a
  standard GitHub-hosted Ubuntu label (`ubuntu-latest`, `ubuntu-24.04`,
  `ubuntu-22.04` and their `-arm` variants) and the build job reported
  `runner.environment == github-hosted` (`scripts/check-build-isolation.sh`).
  A build on a self-hosted runner, which the caller controls and which can
  keep state between jobs, is pushed but not signed, with a warning. On
  GitLab the same holds only for builds on runners the platform team manages.

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
| `scripts/check-build-isolation.sh` | Gate signing on a GitHub-hosted build runner |
| `scripts/verify-provenance.sh` | Verify signature, subject, builder, source |
| `scripts/verify-sbom.sh` | Verify the signed SBOM, its subject and contents, and save it |
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

### Adopting it in a repository (GitHub)

A repository that already builds with `build-and-release.yml` changes nothing
but, at most, the permissions its calling job grants. The signing job needs
`id-token: write` (to federate with GCP; no static key is stored anywhere)
and `packages: write` (to attach the attestations to the image):

```yaml
jobs:
  release:
    permissions:
      contents: write   # git tag
      packages: write   # image push and attestations
      id-token: write   # OIDC token for Workload Identity Federation
    uses: prefeitura-rio/actions/.github/workflows/build-and-release.yml@master
    with:
      push: true
    secrets: inherit
```

Signing runs only when `push: true`, `sign: true` (default) and the org
variables above are set; otherwise the job is skipped and the build is
unaffected. It also needs the build on a GitHub-hosted Ubuntu runner (the
default `runs_on: ubuntu-latest`): with a self-hosted `runs_on` the image is
still built and pushed, but the `provenance` job only warns and signs
nothing (see "Isolated build" above). The `provenance` job itself always
runs on a GitHub-hosted `ubuntu-latest` runner, whatever `runs_on` says: it
is the only job that can federate to the signer, so it never runs on a
runner the caller controls. The WIF provider only trusts
`prefeitura-rio/actions/.github/workflows/build-and-release.yml@refs/heads/master`
(`github_build_workflow_ref` in `infra/kms`), so call the workflow at
`@master`. A caller that pins it by commit SHA or tag gets a different
`job_workflow_ref`, the federation is refused and the `provenance` job fails:
pass `sign: false` there until the trusted ref covers that pin.

### GitLab

Include the component and pass the WIF audience / signer / key as inputs. See
the header of `gitlab/build-sign-release.yml`. Set `gitlab_issuer_uri` and
`gitlab_namespace_path` in the terraform module to match your instance.

## Verify flow

Consumers (a deploy pipeline, an admission policy, a person auditing an
image) verify both attestations against the same trust root: the public key
of the KMS signing key (`cosign.pub`, from `provenance_public_key_pem` above)
or the `gcpkms://` URI of the key version for a caller allowed to read its
public key in KMS. Always verify by digest (`image@sha256:...`), never by
tag. Both scripts need `cosign`, `jq` and `base64`.

### Provenance

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
attaches it as a second signed attestation (`--type cyclonedx`).

### Verifying and collecting the SBOM

`scripts/verify-sbom.sh` enforces: valid signature (via cosign), statement
subject equal to the image digest, CycloneDX predicate type, and a CycloneDX
document with a `specVersion` and at least `MIN_COMPONENTS` components
(default `1`). With `SBOM_FILE` set it writes the verified SBOM there, so
the consumer collects exactly the document that was signed (for a
vulnerability scan, a license audit or an archive) instead of regenerating
it:

```sh
export IMAGE_DIGEST="ghcr.io/prefeitura-rio/app@sha256:..."
export VERIFY_KEY="cosign.pub"   # offline trust root, or gcpkms:// URI
export SBOM_FILE="app.cdx.json"  # optional: where to save the verified SBOM
./scripts/verify-sbom.sh
grype "sbom:app.cdx.json"        # e.g. scan the collected SBOM
```

It exits `1` when verification or policy fails (nothing is saved) and `2`
on invalid input (`IMAGE_DIGEST` not pinned by `sha256` digest, malformed
`MIN_COMPONENTS`). `IGNORE_TLOG` behaves as in `verify-provenance.sh`. The
underlying cosign check, without the policy, is:

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
