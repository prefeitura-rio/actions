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

## GitHub Reusable Workflow

Repositories in the organization can call the reusable workflow while keeping
the release behavior in this portable toolkit:

```yaml
permissions:
  contents: write

jobs:
  release:
    uses: prefeitura-rio/actions/.github/workflows/release.yml@<workflow-sha>
    with:
      release_branch: main
      target_sha: ${{ github.sha }}
      toolkit_ref: <toolkit-sha>
      floating_tag: latest
      bump: patch
```

Both `<workflow-sha>` and `<toolkit-sha>` must be immutable commit SHAs. The
workflow checks out the calling repository for tagging and checks out the
central toolkit at `toolkit_ref` for executing the scripts. The caller's
`GITHUB_TOKEN` needs `contents: write` to create and update tags.

Run the contract tests with:

```bash
bash release/tests/test-version.sh
bash release/tests/test-publish-tags.sh
```
