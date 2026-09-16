# Quality Gate Output Summary Layouts

This document is the working proposal for reworking the output summaries
published by the quality-gate jobs. It describes what each job should show in
`GITHUB_STEP_SUMMARY`, while keeping the portable checks provider-neutral.

## Scope

The reusable workflow currently publishes one summary per matrix job for:

- Format
- Lint
- Structural Lint
- Type Check
- Test

The Detect job is a prerequisite for the matrix and currently exposes its
language list as an output rather than publishing a summary. Whether Detect
should receive a small summary is an open question below.

## Shared Layout

Every summary should make the result understandable without opening the raw
job log. The first lines should provide the check, language/framework, and
outcome. Details should be organized around the information a developer needs
to act on the result.

Proposed common shell:

````markdown
## Format - Python

**Status:** Passed
**Project:** `path/to/project`
**Duration:** 42s

### Result

All files comply with the configured formatter.
````

For failures, the summary should put the actionable diagnosis before verbose
tool output:

````markdown
## Format - Python

**Status:** Failed
**Project:** `path/to/project`

### What failed

3 files need formatting.

### How to fix

```bash
uvx ruff@0.16.4 format .
```

<details>
<summary>Raw tool output</summary>

...
</details>
````

Common rules:

- Use a consistent status label: `Passed`, `Failed`, `Skipped`, or `Expected failure`.
- Include the project path and the detected language; include the framework for Next.js, Vue, and Nuxt.
- Keep the top-level section compact and put long diagnostics in collapsible details.
- Show remediation commands as copyable fenced code blocks.
- Avoid repeating the same outcome in multiple sections.
- Preserve expected-failure context, but distinguish an expected failure from a production failure.
- Keep raw output bounded so a summary remains readable.

## Format

### Purpose

Verify that source files match the formatter and import-organization rules. A
failure should emphasize the affected files and the command that fixes them,
not make the user search through a diff in the job log.

### Layout

````markdown
### Quality Gate: Format (<language/framework>)
Outcome: failure

Error:
```text
<formatter diagnostic and affected files>
```

How to fix it:
```text
<formatter remediation command>
```
````

Notes for discussion:

- Go runs both `gofumpt` and `goimports`; the summary should identify which formatter failed, or show two result rows when both run.
- Python should report Ruff's file list without copying its complete diff into the summary.
- TypeScript should report the framework-aware file paths, including `.vue` and Next.js route files where applicable.
- Complete formatting diffs remain available in the job logs, but are not copied into the summary.
- Format setup failures should use the same diagnostic and remediation template when the tool provides a hint.

## Lint

### Purpose

Report conventional lint violations and, where applicable, complexity or
React-specific diagnostics.

### Layout

````markdown
### Quality Gate: Lint (<language/framework>)
Outcome: failure

Error:
```text
<bounded lint diagnostic output>
```
````

Notes for discussion:

- Keep the diagnostic output bounded; the complete tool output remains in the job logs.
- Preserve the tool's native file, line, rule, and message details rather than guessing at a normalized table.
- Render a `How to fix it` section only when the tool provides a remediation hint.
- Framework-specific TypeScript lint diagnostics remain in the bounded oxlint output.

## Structural Lint

### Purpose

Report organization and repository-local ast-grep rule violations. The key
piece of context is the rule source, because failures can come from mandatory
organization rules or additive repository-local rules.

### Proposed layout

````markdown
## Structural Lint - <language/framework>

**Status:** Passed | Failed
**Project:** `<working-directory>`
**Rule sets:** Organization, Repository-local | Organization only

### Result

<All structural rules passed.>

### Violations

| File | Line | Rule set | Rule | Message |
|---|---:|---|---|---|
| `path/to/file` | 8 | Organization | `no-panic` | Description |

### How to fix

Review the rule violation and update the matching code. If the rule is
repository-local, see `<rule/config path>`.

<details>
<summary>Raw ast-grep output</summary>

```text
<bounded output>
```
</details>
````

Notes for discussion:

- Explicitly distinguish organization rules from repository-local rules.
- Include the rule name prominently; it is the fastest way to locate the policy and understand the violation.
- On success, state whether repository-local rules were run or skipped.
- Do not imply that repository-local rules replace organization rules; they are additive.

## Type Check

### Purpose

Report compiler and static-analysis diagnostics with enough context to locate
the error quickly. This job can use different checkers based on language,
project configuration, and TypeScript framework.

### Layout

````markdown
### Quality Gate: Type Check (<language/framework>)
Outcome: failure

Error:
```text
<diagnostic output provided by the failed tool>
```

How to fix it:
```text
<tool-provided remediation, when available>
```
````

Notes for discussion:

- The template is static, but error and remediation contents come from the tool whenever available.
- The remediation section is shown only when the tool provides a hint or suggested command.
- Tool hints such as `uv`'s `hint:` lines are preserved in the remediation section.
- One error section represents one failed command or phase. Multiple diagnostics from that command remain together.
- For typecheck summaries, setup, download, and generic recent-output noise must not be copied into the summary.
- Diagnostic output is bounded; the complete tool output remains in the job logs.
- If a tool provides no remediation hint, only the error section is shown.

## Test

### Purpose

Summarize test execution and coverage in a way that separates test failures
from coverage-policy failures. Tests are run only after the other four checks
pass in the reusable workflow.

### Proposed layout

````markdown
## Test - <language/framework>

**Status:** Passed | Failed | Expected failure
**Project:** `<working-directory>`
**Runner:** `<go test -race | pytest | npm/pnpm test>`

### Result

| Metric | Value |
|---|---:|
| Tests passed | 24 |
| Tests failed | 0 |
| Tests skipped | 1 |
| Duration | 18s |

### Coverage

| Metric | Value |
|---|---:|
| Total coverage | 86% |
| Required threshold | 80% |
| Result | Passed |

### How to fix

```bash
<local test command>
```

<details>
<summary>Failed tests and raw output</summary>

```text
<bounded output>
```
</details>
````

Notes for discussion:

- Only show the Coverage section for Python, unless another runner later gains a coverage contract.
- If the runner does not emit parseable counts, show a concise result and keep the raw output rather than inventing metrics.
- Make a coverage-threshold failure explicit: report actual coverage, required coverage, and the configuration source when available.
- Warn when a TypeScript test script does not invoke a recognized test binary, while keeping the job result based on the command exit code.
- For Go, mention that tests run with race detection.

## Expected-Failure Summaries

Negative fixtures use `expected-failure: true`. The proposed layout should keep
the same job-specific sections but change the status treatment:

```markdown
## Structural Lint - Go

**Status:** Expected failure
**Assertion:** Passed

The check failed as designed for the negative fixture.

<details>
<summary>Diagnostic</summary>

...
</details>
```

An expected-failure invocation that succeeds should be reported as a failed
test assertion, because the fixture no longer proves the intended behavior.

## Detect Language

Detect should publish a small summary focused on the result of language
detection rather than presenting itself as a formatter or quality check:

```markdown
### Quality Gate: Detect Language

Outcome: success
Error: None
Languages Detected:
- Go
- Python
- TypeScript

The `Languages Detected` section supports all three result shapes:

- A single detected language is rendered as one list item.
- Multiple detected languages are rendered as one list item per language.
- No detected languages is rendered as `Languages Detected: None`.

When no supported language is found, the summary should still be written with
`Outcome: failure`, the existing detection diagnostic, and no language values:

```text
### Quality Gate: Detect Language

Outcome: failure
Error: Could not detect a supported language. ...
Languages Detected: None
```

The `languages` action output remains the JSON array used by the reusable
workflow matrix. The summary renderer receives that output separately and
formats it for human-readable display.

## Decisions Needed

- Should the renderer continue to be one shared script with job-specific sections, or should each check own a dedicated renderer?
- Should summary titles use `##` headings and reserve `###` for details, replacing the current `### Quality Gate:` title?
- Which fields can be normalized reliably across all tools: counts, file/line locations, rule codes, duration, and coverage?
- Should raw tool output be collapsed by default for every job, or only when it exceeds a size threshold?
- Should the working-directory and tool versions be shown in production summaries?
- Should summary layout changes update `summary_name` and the existing adapter contract, or only change the body written to `GITHUB_STEP_SUMMARY`?

## Implementation Boundary

The summary renderer may consume structured metadata in addition to the current
error file and success marker. The portable check scripts should continue to
own check behavior and return diagnostics through their existing contract. The
GitHub adapter should remain responsible for formatting and publishing the
provider-specific summary.
