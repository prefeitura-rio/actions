# How Quality-Gate Itself Is Tested

Quality-gate is tested at several levels so that clean projects remain green,
real violations are rejected, and failures explain what needs to be fixed.

## Local Portable Tests

The provider-neutral contract is tested without GitHub environment variables:

```bash
bash quality-gate/tests/scripts/test-portable.sh
```

These tests cover language detection, invalid checks, TypeScript framework and
package-manager metadata, shared error collection, summary rendering, and the
invocation contract of every language entrypoint. The GitHub workflow remains
responsible for adapter behavior and fixture coverage, including setup actions,
action outputs, error relay, and friendly summary-name behavior.

## What Is Tested and Why

The organization structural rules are tested with small valid and invalid code
examples. Valid examples must not be flagged, while invalid examples must be
flagged. This protects the rules from silently changing behavior when a rule,
parser, or ast-grep version changes.

The action is run against clean and deliberately broken fixture projects for
each supported language and quality check. Language fixtures live beside their
action in `quality-gate/go/fixtures/`, `quality-gate/python/fixtures/`, and
`quality-gate/typescript/fixtures/`. The TypeScript fixtures include plain
TypeScript, Vue, and Nuxt projects. Shared detection and validation fixtures
remain in `quality-gate/fixtures/error/`. Clean fixtures prove that valid code
is accepted. Broken fixtures prove that formatting, lint, structural lint,
typecheck, and test failures are detected. This tests the complete action path,
including language detection, dispatch from the root action, language-specific
action setup, configuration precedence, strict organization fallbacks, React,
Vue, and Nuxt framework detection, Vue SFC handling, and the quality command,
rather than only isolated shell conditions.

Defensive error scenarios are tested separately. They cover invalid check
names, unsupported projects, missing TypeScript lockfiles, corrupted tool
downloads, and language override validation. The tests check both that the
action fails and that the reported message is exact. This keeps configuration
errors actionable instead of reducing them to an unexplained exit code.

Multi-language detection is tested with `detect-only` checks on single-language
and polyglot directories, verifying that the correct JSON array is output.
Language override validation is tested by requesting a language that doesn't
match the project's markers (rejected) and by requesting the correct language
(explicit override accepted).

## Test jobs overview

| Job | What it tests |
|-----|---------------|
| `reusable-workflow` | End-to-end smoke test of the reusable workflow on a Go project |
| `ast-grep-rules` | ast-grep rule correctness for Go, Python, TypeScript |
| `portable-scripts` | Provider-neutral shell and Node entrypoint contracts without GitHub variables |
| `go` | All 5 checks (format, lint, strlint, typecheck, test) pass/fail for Go |
| `python` | All 5 checks (format, lint, strlint, typecheck, test) pass/fail for Python |
| `typescript` | All 5 checks pass/fail for TypeScript, Vue, and Nuxt fixtures, including framework-aware summary names |
| `error-invalid-check` | Invalid check names are rejected with exact error message |
| `setup-py-success` | `setup.py`-only project is accepted as Python |
| `detect-single-language` | `detect-only` returns correct JSON for Go, Python, TypeScript, Vue, and Nuxt |
| `detect-multi-language` | `detect-only` returns all 3 languages for polyglot directory |
| `detect-no-language` | `detect-only` fails on empty directory |
| `language-override-rejected` | Explicit `language` input is validated against detected markers |
| `language-override-accepted` | Explicit `language` input works when it matches |
| `repo-local-rules` | Repository-local ast-grep rules are detected and enforced |
| `mandatory-policy-rules` | Mandatory org rules (no-panic, no-eval, etc.) fail on violations |
| `polyglot-project-paths` | Polyglot subdirectories route to correct language action |
| `error-no-language` | Empty directory fails with expected error |
| `error-ts-no-lockfile` | TypeScript without lockfile fails with expected error |
| `error-py-no-lockfile` | Python typecheck without `uv.lock` fails with a lockfile diagnostic |
| `error-ts-no-tsconfig` | package.json without tsconfig.json fails (not detected as TypeScript) |
| `error-gofumpt-sha-mismatch` | Corrupted gofumpt download triggers sha256 error + cleanup |
| `error-ast-grep-sha-mismatch` | Corrupted ast-grep download triggers sha256 error + cleanup |
| `error-multi-language-no-override` | Normal check fails on multi-language directory without explicit override |
| `repo-rule-precedence` | Root `sgconfig.yaml` takes precedence over `.quality-gate/sgconfig.yaml` |

The Python typecheck matrix uses the passing fixture to exercise project
`[tool.basedpyright]` configuration and `typecheck-fail` to exercise the
organization `pyrightconfig.json` fallback.

## How to Read a Failure

For the quality checks, a failure identifies the language, check, and fixture
that produced it. Error-path failures also show the expected and actual error
message. Formatter failure assertions verify that the error output identifies
the formatter, affected files, formatting diff, and a local remediation command;
separate assertions verify friendly summary names. The final totals show whether
the complete suite passed or whether one or more checks require investigation.

## Summary Format

The action writes a summary block to `GITHUB_STEP_SUMMARY`. The format
distinguishes standard invocations from expected-failure test invocations:

**Standard invocation (production or passing fixture):**

```text
### Quality Gate: Type Check (Python)

Outcome: success
Error:
None
```

**Expected-failure test invocation:**

```text
### Quality Gate: Type Check (Python)

Outcome: failure
Error:
Command failed (exit 1): basedpyright ...
...

## Test

Test scenario: expected failure
Outcome: failure
Expected outcome: failure
```

The `## Test` section appears only when `expected-failure: true` is passed to
the action. It signals that the failure is intentional and was asserted by the
test job. In production workflows, this input is omitted and the summary remains
a simple pass/fail report.
