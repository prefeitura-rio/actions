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
| `scripts/move-floating-tag.sh` | Move a floating tag to the release branch tip without a version tag. |

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

Floating tags are annotated after a successful atomic publication. Their tag
message identifies the immutable version they point to, for example:

```text
Latest release: quality-gate-v1.1.0
```

`move-floating-tag.sh` pushes the floating tag atomically with a lease on the
release branch: if the branch tip is no longer the target commit, the push is
rejected and the floating tag stays where it was. It refuses tag names that
end in a semantic version, so it never moves an immutable version tag.

## Repository Release (`latest` and `v<X.Y.Z>`)

The **Actions Release** workflow (`.github/workflows/actions-release.yml`)
publishes repository-wide tags for this repository:

- On every push to `master`, the `Update latest tag` job moves `latest` to the
  pushed commit, unless `master` has already moved on (a newer push updates it).
- Run **Actions Release** from the Actions tab to publish a stable `v<X.Y.Z>`
  tag: choose the bump and, optionally, the full commit SHA (empty releases the
  current tip of `master`). The first release is `v1.0.0`. The target must
  still be the tip of `master`; `latest` then points to the new version.

To roll a consumer back, pin it to a previous `v<X.Y.Z>` tag.

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
bash release/tests/test-move-floating-tag.sh
```
