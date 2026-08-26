# How Quality-Gate Itself Is Tested

Quality-gate is tested at several levels so that clean projects remain green,
real violations are rejected, and failures explain what needs to be fixed.

## What Is Tested and Why

The organization structural rules are tested with small valid and invalid code
examples. Valid examples must not be flagged, while invalid examples must be
flagged. This protects the rules from silently changing behavior when a rule,
parser, or ast-grep version changes.

The action is run against clean and deliberately broken fixture projects for
each implemented language and quality-check path. Clean fixtures prove that
valid code is accepted. Broken fixtures prove that formatting, lint, structural
lint, typecheck, and test failures are detected. Python typecheck is tested as
the documented no-op because basedpyright runs under lint. These fixtures test
the complete action path, including tool setup and language detection, rather
than only the shell conditions around it.

Defensive error scenarios are tested separately. They cover literal and
regex-like invalid check names, unsupported projects, ambiguous polyglot roots,
legacy setup.py-only projects, missing TypeScript lockfiles, and corrupted tool
downloads. The tests check both that the action fails and that the reported
message is exact. This keeps configuration errors actionable instead of
reducing them to an unexplained exit code.

Repository-local structural rules have one failing fixture per language. Each
organization rule documented as mandatory has its own failing policy fixture,
proving that every rule independently exits nonzero rather than merely printing
a warning.
The passing Go fixture includes an ordinary project `tests/` directory so a
regression cannot reinterpret application tests as ast-grep rule tests.

A polyglot fixture keeps a TypeScript application and Python service under
arbitrary nested paths. Separate invocations prove that `working-directory`
selects each project without relying on names such as frontend, backend, API,
or library.

The test workflow also calls the repository-local reusable workflow against a
passing Go fixture. This verifies the five-job orchestration and its
project-name/working-directory input contract in a real GitHub runner.

The template bootstrap scripts are tested with all eight templates. The tests
cover successful renaming, repeated execution, invalid input, non-interactive
use, cancelled confirmation, and the final environment-trust command. This
protects the first-run experience that creates a developer's project from a
template.

## Historical GitHub Actions Output

The following output was copied from GitHub Actions run 32785747539. Every job
reported success. The order is the order returned by the GitHub Actions run
summary.

```text
success  error-no-language
success  go (app:lint)
success  go (app:typecheck)
success  python (app:strlint)
success  typescript (app:typecheck)
success  go (app:strlint)
success  error-ts-no-tsconfig
success  error-invalid-check
success  python (app:test)
success  go (app:format)
success  python (app:format)
success  error-ts-no-lockfile
success  python (app:lint)
success  typescript (app:lint)
success  typescript (app:strlint)
success  typescript (app:format)
success  go (app:test)
success  typescript (app:test)
```

This run predates the expanded exact-message assertions, checksum-mismatch
jobs, local-rule fixtures, ambiguity checks, and mandatory-policy fixtures. It
is retained as historical evidence rather than a description of the current
job count.

## Trigger Scope

The self-tests run on pull requests and pushes to `master` only when
`quality-gate/**`, the reusable quality-gate workflow, or this test workflow
changes. They can also be started manually. Unrelated changes to other actions
do not launch the quality-gate fixture matrix.

## Real Bootstrap Output

The following output was copied from a local run after the regression harness
was relocated into the tracked actions repository. All 31 checks passed.

```text
=== TST-006: Bootstrap script regression tests ===

--- go-projects-template/api ---
  PASS  go-api: happy path
  PASS  go-api: idempotency
  PASS  go-api: invalid module path rejected
  PASS  go-api: non-interactive detected
  PASS  go-api: confirmation n — no files changed

--- go-projects-template/cli ---
  PASS  go-cli: happy path
  PASS  go-cli: idempotency
  PASS  go-cli: non-interactive detected
  PASS  go-cli: digit-leading command name rejected, no files changed
  PASS  go-cli: Go keyword command name rejected, no files changed
  PASS  go-cli: placeholder command name rejected, no files changed

--- go-projects-template/library ---
  PASS  go-lib: happy path
  PASS  go-lib: idempotency
  PASS  go-lib: non-interactive detected

--- python-projects-template/api ---
  PASS  py-api: happy path
  PASS  py-api: idempotency
  PASS  py-api: invalid name rejected
  PASS  py-api: non-interactive detected

--- python-projects-template/library ---
  PASS  py-lib: happy path
  PASS  py-lib: idempotency
  PASS  py-lib: non-interactive detected

--- typescript-projects-template/backend ---
  PASS  ts-backend: happy path
  PASS  ts-backend: idempotency
  PASS  ts-backend: non-interactive detected

--- typescript-projects-template/frontend ---
  PASS  ts-frontend: happy path
  PASS  ts-frontend: idempotency
  PASS  ts-frontend: non-interactive detected

--- typescript-projects-template/library ---
  PASS  ts-lib: happy path
  PASS  ts-lib: idempotency
  PASS  ts-lib: non-interactive detected

--- install section: devenv allow invocation ---
  PASS  install: devenv allow invoked at end of bootstrap

=== Results: 31 passed, 0 failed, 31 total ===
```

## How to Read a Failure

For the quality checks, a failure identifies the language, check, and fixture
that produced it. Error-path failures also show the expected and actual error
message. For the bootstrap tests, each failure names the template and scenario
that failed. The final totals show whether the complete suite passed or whether
one or more checks require investigation.
