# prefeitura-rio/actions

Shared composite GitHub Actions for org-wide CI/CD pipelines.
Consumed by all `repo-templates` projects and any project following org conventions.

## Actions

| Action | Purpose |
|---|---|
| [`quality-gate/`](quality-gate/) | Format, lint, structural lint, typecheck, test — language-agnostic |
| [`sast/`](sast/) | Security scanning: opengrep, grype/SBOM, checkov, SonarQube |
| [`setup-devenv/`](setup-devenv/) | Install and activate the Nix/devenv dev environment |

## Quick start — quality-gate

```yaml
- uses: prefeitura-rio/actions/quality-gate@master
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
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: api
      working-directory: services/api

  library-quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: library
      working-directory: libraries/shared
```

The reusable workflow auto-detects all languages in the project directory and
runs checks for each language in parallel via matrix.
