# prefeitura-rio/actions

Shared composite GitHub Actions and SAST GitLab CI templates for org-wide CI/CD pipelines.
Consumed by all `repo-templates` projects and any project following org conventions.

## Actions

| Action | Purpose |
|---|---|
| [`quality-gate/`](quality-gate/) | Format, lint, structural lint, typecheck, test — language-agnostic |
| [`sast/`](sast/) | Security scanning: opengrep, grype/SBOM, checkov, SonarQube |
| [`setup-devenv/`](setup-devenv/) | Install and activate the Nix/devenv dev environment |

## Quick start — quality-gate

```yaml
- uses: prefeitura-rio/actions/quality-gate@quality-gate-v1.0.0
  with:
    check: app:format
```

Valid values for `check`: `app:format`, `app:lint`, `app:strlint`, `app:typecheck`, `app:test`, `detect-only`.

Optional input: `language` — explicit language override (`go`, `python`, `typescript`).
When omitted, detection runs from marker files.

See [`quality-gate/README.md`](quality-gate/README.md) for full reference.

Polyglot and multi-project repositories can call the reusable workflow once per
explicit project path:

```yaml
jobs:
  api-quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@quality-gate-v1.0.0
    with:
      project-name: api
      working-directory: services/api

  library-quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@quality-gate-v1.0.0
    with:
      project-name: library
      working-directory: libraries/shared
```

The reusable workflow auto-detects all languages in the project directory and
runs checks for each language in parallel via matrix.

## GitLab SAST

Only SAST has GitLab equivalents; the GitHub actions remain available.
Include the scanner job from the actions project:

```yaml
include:
  - project: prefeitura-rio/actions
    ref: main
    file: /templates/sast/template.yml

variables:
  SAST_ACTIONS_PROJECT: prefeitura-rio/actions
  SAST_ACTIONS_REF: main
```

For reproducible production runs, use the same immutable tag in both `ref` and
`SAST_ACTIONS_REF`. The pipeline creator needs access to the private actions
project. Add the consuming project/group to the actions project's **CI/CD job
token allowlist** so jobs can clone the scripts with `CI_JOB_TOKEN`.
The clone URL honors GitLab's protocol and port (`CI_SERVER_FQDN`, GitLab 16.10+).
The default job image is Debian; jobs need permission to install its packages.

Scanner errors fail the job after the other scanners and summary finish.
JSON/SARIF reports and `sast-summary.md` are uploaded even on failure. Findings
alone are not a standalone scanner gate: the existing `BREAK_ON` summary gate
uses SonarQube results when SonarQube is configured.

Reusable hidden jobs are also available independently:

| Include file | Reuse with `!reference` |
|---|---|
| `/templates/tailscale/template.yml` | `[.tailscale-up, before_script]` |
| `/templates/java-setup/template.yml` | `[.setup-java, script]` |
| `/templates/sonarqube/template.yml` | `[.run-sonarqube, script]` |

Each template documents its dependencies and variables. SonarQube requires
`SONAR_HOST_URL` and a masked `SONAR_TOKEN`; standalone scans do not require
SAST reports. For Community, set `SONAR_BRANCH_ANALYSIS: "false"` and restrict
the job to the default branch. Branch/MR analysis requires a capable edition.
For the combined SAST job, override its `rules` accordingly when using Community.

Tailscale is optional. Supply a masked `TS_OAUTH_SECRET` with `auth_keys` scope
and authorized `TS_TAGS` to register an isolated CI node
([OAuth requirements](https://tailscale.com/kb/1215/oauth-clients)).
The hidden job sources its script so userspace proxy exports survive. Clients
must honor those proxy variables; tools that do not require a TUN-capable,
isolated runner. Do not run this setup against a developer's host daemon.
DefectDojo upload is enabled only when its credentials are supplied; keep
production credentials out of disposable test environments.
DefectDojo collection is best-effort on the default branch. Authentication,
connection, report-preparation, and import failures produce warnings without
failing the scan or skipping its summary and security gate. Tracking requests
have a 10-second connection timeout and a 60-second total timeout. Scanner
failures and configured security gates—not tracking availability—determine
the CI result.

CycloneDX inventory contains only synthetic `Info` findings; Grype uploads the
actual dependency vulnerabilities separately. Inventory IDs are stable hashes
bounded to fit DefectDojo's 50-character vulnerability-ID field, while the full
component metadata is retained. Adopting this ID format can cause a one-time
close/recreate of older inventory findings. Sonar imports exclude `external_*`
rules so scanner findings are not uploaded again through SonarQube.

DefectDojo 3.0.200 and 3.3.200's REST JSON Sonar parsers do not populate
`unique_id_from_tool`, although their default matching algorithm requires it.
For stable reimports of this format, configure the DefectDojo server with
`DD_DEDUPLICATION_ALGORITHM_PER_PARSER={"SonarQube Scan detailed":"hash_code"}`.
The disposable local environment includes this setting; it does not change any
production server configuration.

The GitHub composite action uses the same upload scripts and unchanged inputs.
Tracking failures are nonblocking in both CI integrations. Inventory generation
uses Python 3, already required by tool-cache setup; HTTP failure detection uses
the portable `curl --fail` option inside the isolated tracking block.
