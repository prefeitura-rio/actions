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
| `go` | All 5 checks (format, lint, strlint, typecheck, test) pass/fail for Go |
| `python` | All 4 checks (format, lint, strlint, test) pass/fail for Python |
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
| `error-ts-no-tsconfig` | package.json without tsconfig.json fails (not detected as TypeScript) |
| `error-gofumpt-sha-mismatch` | Corrupted gofumpt download triggers sha256 error + cleanup |
| `error-ast-grep-sha-mismatch` | Corrupted ast-grep download triggers sha256 error + cleanup |

## How to Read a Failure

For the quality checks, a failure identifies the language, check, and fixture
that produced it. Error-path failures also show the expected and actual error
message. Formatter failures additionally verify that the summary identifies the
formatter, affected files, formatting diff, and a local remediation command. The
final totals show whether the complete suite passed or whether one or more
checks require investigation.
