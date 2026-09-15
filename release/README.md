# Release Toolkit

This directory contains provider-neutral release scripts.

The scripts use Git repositories and explicit command-line arguments. They do
not read GitHub, GitLab, runner, or CI-provider environment variables.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/calculate-version.sh` | Calculate the next stable semantic version. |
| `scripts/validate-target.sh` | Confirm that a target commit is still the release branch tip. |
| `scripts/publish-tags.sh` | Create an immutable version tag and update a floating tag. |

Scripts emit `key=value` records on stdout and diagnostics on stderr. A CI
provider adapter can map those records to its native outputs.

Run the contract tests with:

```bash
bash release/tests/test-version.sh
bash release/tests/test-publish-tags.sh
```
