# AGENTS.md

Shared composite actions and reusable workflows for CI/CD across the
`prefeitura-rio` organization: `quality-gate/`, `sast/`, `provenance/`,
`setup-devenv/`, `release/` and `.github/workflows/`. See `README.md` and the
README of each directory before changing it.

## Compatibility

Consumers pin these actions by `@master`, by commit SHA, by the repository
tags `latest` and `v<X.Y.Z>` or by the tags `quality-gate-v<X.Y.Z>` and
`quality-gate-latest`. A merge into `master` takes
effect immediately for every consumer of `@master`, so keep the contract
backward compatible: inputs, outputs, job and check names, and default
behavior. Put new behavior behind a new optional input instead of changing an
existing default.

## Tests

Portable tests need only `bash` and `git` (no GitHub variables):

```bash
bash quality-gate/tests/scripts/test-portable.sh
bash release/tests/test-version.sh
bash release/tests/test-publish-tags.sh
bash release/tests/test-move-floating-tag.sh
bash .github/scripts/tests/test-check-reusable-workflow-refs.sh
```

SLSA provenance scripts (`provenance/scripts`, needs `bash`, `jq` and
`base64`; `cosign` is replaced by a stub, so no cloud credential is used):

```bash
bash provenance/tests/test-provenance.sh
```

Python package of the quality gate (`quality-gate/cli`, needs `uv`):

```bash
cd quality-gate/cli
uv run --frozen ruff format --check . && uv run --frozen ruff check .
uv run --frozen basedpyright && uv run --frozen pytest
```

ast-grep rule tests. ast-grep comes with `devenv shell`; without it,
`install-ast-grep.sh` downloads the pinned binary and prints its path, which
must go on `PATH` (the CI does the same):

```bash
PATH="$(dirname "$(bash quality-gate/scripts/install-ast-grep.sh)"):$PATH"
ast-grep test --skip-snapshot-tests --config quality-gate/go/sgconfig.yaml
ast-grep test --skip-snapshot-tests --config quality-gate/python/sgconfig.yaml
ast-grep test --skip-snapshot-tests --config quality-gate/typescript/sgconfig.yaml
```

The fixture-based end-to-end tests of the actions run only in the
`Quality Gate Tests` workflow (`.github/workflows/quality-gate-tests.yml`).
`quality-gate/docs/testing.md` describes every test job.

## Lint

The dev environment is defined in `devenv.nix`. Inside `devenv shell` the git
hooks run on every commit: actionlint, shellcheck, ruff, ruff-format and
ripsecrets. Run them over the whole tree with:

```bash
devenv test
```

`devenv.nix` also configures shfmt under `treefmt.config.programs`, but
treefmt itself is not enabled there, so shfmt does not run in the hooks and
there is no `treefmt` command in the shell. Keep shell scripts shfmt-clean by
hand (`shfmt -d <file>`) when shfmt is available.

## CI

- `Quality Gate Tests` (`.github/workflows/quality-gate-tests.yml`) runs on
  pull requests to `master` and on pushes to `master`, only when the diff
  touches `quality-gate/`, `release/`, `provenance/`, `.github/scripts/` or the
  quality gate and release workflows.
- `Security` (`.github/workflows/ci.yml`, the local `sast` action) runs on
  pushes to `master` and `feat/**`, only when the diff touches the paths listed
  in that workflow; it does not run on pull requests.
- When both pass for a push to `master`, `Quality Gate Release` publishes
  `quality-gate-v<X.Y.Z>` and moves `quality-gate-latest`.
- `Actions Release` (`.github/workflows/actions-release.yml`) moves the tag
  `latest` to the tip of `master` on every push to `master`, and publishes an
  immutable `v<X.Y.Z>` (and moves `latest` to it) when run manually.
- `Workflow Refs` (`.github/workflows/workflow-refs.yml`) runs on pull
  requests to `master` and on pushes to `master` when the diff touches
  `.github/workflows/` or `.github/scripts/`. It fails when a reusable workflow
  resolves its own actions or scripts at `master` or a floating tag instead of
  the commit the caller pinned (`$/<path>`, `job.workflow_sha`); only the
  `quality-gate-latest` steps reserved for `@master` callers are allowed. It is
  not a release gate.
