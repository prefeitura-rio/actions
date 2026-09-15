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
      floating_tag: my-app-latest
      tag_prefix: my-app-v
      bump: patch
```

Both `<workflow-sha>` and `<toolkit-sha>` must be immutable commit SHAs. The
workflow checks out the calling repository for tagging and checks out the
central toolkit at `toolkit_ref` for executing the scripts. The caller's
`GITHUB_TOKEN` needs `contents: write` to create and update tags. Use a
component-specific `tag_prefix` and `floating_tag` when a repository contains
more than one releasable action or application.

## Manual Quality-Gate Release

Run **Manual Quality Gate Release** from the Actions tab and provide the full
commit SHA to release plus a version bump. The workflow releases only when
both `Quality Gate Tests` and `Security` have already completed successfully
for that exact commit, and the commit is still the tip of `master`.

The manual workflow does not rerun the checks. If either required workflow is
still running or failed, retry the manual dispatch after the checks complete.

Run the contract tests with:

```bash
bash release/tests/test-version.sh
bash release/tests/test-publish-tags.sh
```
