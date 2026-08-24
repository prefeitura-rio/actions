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

Valid values for `check`: `app:format`, `app:lint`, `app:strlint`, `app:typecheck`, `app:test`.

See [`quality-gate/README.md`](quality-gate/README.md) for full reference.

## Related issues

| Issue | Description |
|---|---|
| INFRAVPIA-224 | Epic |
| INFRAVPIA-227 | Repo templates and quality-gate implementation |
| INFRAVPIA-229 | CAIO AI check and portaria CLI (CI-008, CI-009) |
| INFRAVPIA-249 | Tag release workflow for this repo |
