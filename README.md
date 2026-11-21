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
frozen with the archived Quality Gate: the quality gate release workflows no
longer publish or move them (see [`quality-gate/README.md`](quality-gate/README.md)).
`@master` and commit SHAs keep working.

## Quick start — quality-gate

> **Archived.** The GitHub Actions Quality Gate in this repository is frozen
> for compatibility with existing consumers. New consumers should use the
> Quality Gate profile of
> [`prefeitura-rio/flakes`](https://github.com/prefeitura-rio/flakes) and its
> published Nix app:
>
> ```yaml
> inputs:
>   prefrio:
>     url: github:prefeitura-rio/flakes
> imports:
>   - prefrio/devenv/quality-gate.nix
> ```

Existing consumers of the legacy GitHub adapter keep working with the frozen
`quality-gate-latest` tag, which no longer receives new rules, tools or
releases:

```yaml
- uses: prefeitura-rio/actions/quality-gate@quality-gate-latest
  with:
    check: app:format
```

Valid values for `check`: `app:format`, `app:lint`, `app:strlint`, `app:typecheck`, `app:test`, `detect-only`.

Optional input: `language` — explicit language override (`go`, `python`, `typescript`).
When omitted, detection runs from marker files.

See [`quality-gate/README.md`](quality-gate/README.md) for full reference.

Polyglot and multi-project repositories on the legacy adapter can call the
reusable workflow once per explicit project path:

```yaml
jobs:
  api-quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@quality-gate-latest
    with:
      project-name: api
      working-directory: services/api

  library-quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@quality-gate-latest
    with:
      project-name: library
      working-directory: libraries/shared
```

The reusable workflow auto-detects all languages in the project directory and
runs checks for each language in parallel via matrix.
