# AGENTS.md

Shared composite actions and reusable workflows for CI/CD across the
`prefeitura-rio` organization: `quality-gate/`, `sast/`, `provenance/`,
`setup-devenv/`, `release/` and `.github/workflows/`. See `README.md` and the
README of each directory before changing it.

## Compatibility

Consumers pin these actions by `@master`, by commit SHA or by the tags
`quality-gate-v<X.Y.Z>` and `quality-gate-latest`. A merge into `master` takes
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
```

ast-grep rule tests (ast-grep comes with `devenv shell`, or from
`bash quality-gate/scripts/install-ast-grep.sh`):

```bash
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
ripsecrets; shfmt runs through treefmt. Run them over the whole tree with:

```bash
devenv test
treefmt
```

## CI

- Pull requests to `master`: only `Quality Gate Tests`, and only when the diff
  touches `quality-gate/`, `release/`, `.github/scripts/` or the quality gate
  and release workflows.
- Push to `master` and `feat/**`: `Security` (`.github/workflows/ci.yml`, the
  local `sast` action).
- After both pass on `master`, `Quality Gate Release` publishes
  `quality-gate-v<X.Y.Z>` and moves `quality-gate-latest`.
