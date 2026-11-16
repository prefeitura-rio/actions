# prefeitura-rio/actions

Shared composite GitHub Actions for org-wide CI/CD pipelines.
Consumed by all `repo-templates` projects and any project following org conventions.

## Actions

| Action | Purpose |
|---|---|
| [`quality-gate/`](quality-gate/) | Format, lint, structural lint, typecheck, test — language-agnostic; opt-in AI styleguide review (`quality-gate/ai-review`) |
| [`sast/`](sast/) | Security scanning: opengrep, grype/SBOM, checkov |
| [`provenance/`](provenance/) | SLSA L3 build provenance: KMS-signed in-toto attestations (GitHub + GitLab) |
| [`setup-devenv/`](setup-devenv/) | Install and activate the Nix/devenv dev environment |

## Versions

Every action and reusable workflow in this repository can be pinned by the
same repository-wide tags, published by the `Actions Release` workflow
(`.github/workflows/actions-release.yml`):

| Ref | Moves? | Published |
|---|---|---|
| `latest` | yes | automatically, on every push to `master`, pointing to its tip |
| `v<X.Y.Z>` | never | on demand: run **Actions Release** from the Actions tab and pick the bump (`patch`, `minor`, `major`); `latest` then points to the new version |

```yaml
- uses: prefeitura-rio/actions/sast@latest    # follows master
- uses: prefeitura-rio/actions/sast@v1.0.0    # stable, use for rollback
```

Pinning a reusable workflow by `v<X.Y.Z>` also pins the actions and scripts of
this repository it runs: they are resolved at the commit the caller pinned
(`$/<path>`, `job.workflow_sha`), and the `Workflow Refs` check keeps it that
way. The only exception is `.github/workflows/quality-gate.yml` called by
`@master`, which keeps running `quality-gate@quality-gate-latest`.

The component tags `quality-gate-v<X.Y.Z>` and `quality-gate-latest` are
published independently by the quality gate release workflows (see
[`release/README.md`](release/README.md)). `@master` and commit SHAs keep
working.

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
