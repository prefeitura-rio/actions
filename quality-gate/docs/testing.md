# How Quality-Gate Itself Is Tested

Quality-gate is tested at several levels so that clean projects remain green,
real violations are rejected, and failures explain what needs to be fixed.

## What Is Tested and Why

The organization structural rules are tested with small valid and invalid code
examples. Valid examples must not be flagged, while invalid examples must be
flagged. This protects the rules from silently changing behavior when a rule,
parser, or ast-grep version changes.

The action is run against clean and deliberately broken fixture projects for
each supported language and quality check. Language fixtures live beside their
action in `quality-gate/go/fixtures/`, `quality-gate/python/fixtures/`, and
`quality-gate/typescript/fixtures/`. Shared detection and validation fixtures
remain in `quality-gate/fixtures/error/`. Clean fixtures prove that valid code
is accepted. Broken fixtures prove that formatting, lint, structural lint,
typecheck, and test failures are detected. This tests the complete action path,
including language detection, dispatch from the root action, language-specific
action setup, configuration precedence, strict organization fallbacks, React
project detection, and the quality command, rather than only isolated shell
conditions.

Defensive error scenarios are tested separately. They cover invalid check
names, unsupported projects, missing TypeScript lockfiles, and corrupted tool
downloads. The tests check both that the action fails and that the reported
message is exact. This keeps configuration errors actionable instead of
reducing them to an unexplained exit code.

The template bootstrap scripts are tested with all eight templates. The tests
cover successful renaming, repeated execution, invalid input, non-interactive
use, cancelled confirmation, and the final environment-trust command. This
protects the first-run experience that creates a developer's project from a
template.

## Real GitHub Actions Output

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

This run predates the expanded exact-message assertions and checksum-mismatch
jobs. Those scenarios are intentionally not presented as runner-verified yet;
their first live result is tracked as a pending testing task in the roadmap.

## How to Read a Failure

For the quality checks, a failure identifies the language, check, and fixture
that produced it. Error-path failures also show the expected and actual error
message. The final totals show whether the complete suite passed or whether
one or more checks require investigation.
