# Quality-Gate

Language-agnostic composite GitHub Action that runs a single quality check on
any Go, Python, or TypeScript project. Detects the project language automatically
from marker files and executes the appropriate tool for the requested check.
Supports polyglot repositories — detects all present languages and runs checks
for each in parallel via matrix.

---

## Using the action

### Inputs

| Input      | Required | Valid values                                                             |
| ---------- | -------- | ------------------------------------------------------------------------ |
| `check`    | yes      | `app:format` · `app:lint` · `app:strlint` · `app:typecheck` · `app:test` · `detect-only` |
| `working-directory` | no  | Directory to run checks in (default: `.`)                               |
| `language` | no       | Explicit language override: `go`, `python`, `typescript`                 |

### Outputs

| Output        | Description |
| ------------- | ----------- |
| `error_message` | Human-readable error message set when the action fails. |
| `languages`   | JSON array of detected languages (e.g. `["go","typescript"]`). Set only when `check: detect-only`. |

### Language detection

| Marker file                      | Detected language |
| -------------------------------- | ----------------- |
| `go.mod`                         | Go                |
| `pyproject.toml` or `setup.py`   | Python            |
| `package.json` + `tsconfig.json` | TypeScript        |

If none of these marker files exist the action exits with an error.

When `check: detect-only`, the action outputs all detected languages as a JSON
array via the `languages` output. This enables the reusable workflow to matrix
over languages for parallel execution.

When `check` is a normal check (e.g. `app:format`) and multiple languages are
detected, the action exits with an error unless `language` is provided. Use
`detect-only` to enumerate languages, then call the action once per language.

---

## Check reference

### `detect-only`

Detect all supported languages in the working directory. Outputs a JSON array
via the `languages` output. Does not run any quality checks.

Example output: `["go","python","typescript"]`

### `app:format`

Fail on any formatting diff. Never auto-fixes in CI.

| Language   | Tool                | Version                 |
| ---------- | ------------------- | ----------------------- |
| Go         | gofumpt + goimports | v0.8.0 / v0.35.0        |
| Python     | ruff format         | via uv (project-pinned) |
| TypeScript | oxfmt               | 0.62.0 (via npx)        |

### `app:lint`

Static analysis. Runs on all three languages.

| Language   | Tool                      | Version                 |
| ---------- | ------------------------- | ----------------------- |
| Go         | golangci-lint             | v2.12.2                 |
| Python     | ruff check + complexipy   | ruff via uv (project-pinned) · complexipy 7.0.1 (via uvx) |
| TypeScript | oxlint + react-doctor    | oxlint 0.16.7 (via npx) · react-doctor 0.9.12 (via npx, React projects) |

### `app:strlint`

Structural lint using ast-grep. Runs in two passes:

1. **Org rules** — bundled with the action, always applied.
2. **Repo-local rules** — detected at runtime from a `sgconfig.yaml` or `rules/` directory in the consuming repo.

```bash
# Pass 1 — org rules (always runs)
ast-grep scan --config <action-path>/<lang>/rules

# Pass 2 — repo-local rules (only if present)
ast-grep scan   # uses repo's own sgconfig.yaml
```

#### Org rules

| Language   | Rule ID                  | Severity | What it catches                                                             |
| ---------- | ------------------------ | -------- | --------------------------------------------------------------------------- |
| Go         | `no-panic`               | error    | `panic(...)` outside test files                                             |
| Go         | `no-http-default-client` | warning  | `http.DefaultClient`, `http.Get`, `http.Post`, `http.Head`, `http.PostForm` |
| Go         | `no-plain-error-wrap`    | warning  | `fmt.Errorf("...: %v", err)` instead of `%w`                                |
| Python     | `no-print`               | warning  | `print(...)` outside test files                                             |
| Python     | `no-bare-except`         | warning  | bare `except:` clause (no exception type specified)                         |
| Python     | `no-eval`                | error    | `eval(...)` and `exec(...)`                                                 |
| TypeScript | `no-any-assertion`       | error    | `expr as any` outside test files                                            |
| TypeScript | `no-console`             | warning  | `console.log`, `.warn`, `.error`, `.info`, `.debug`                         |

### `app:typecheck`

Type checking and compilation verification.

| Language   | Command                                    | Notes                                        |
| ---------- | ------------------------------------------ | -------------------------------------------- |
| Go         | `go vet ./...` + `go build -o /dev/null`   | Builds `./cmd/...` if present, otherwise `.` |
| Python     | `ty check` (strict: all rules at error)     | ty 0.0.74 (via uvx)                          |
| TypeScript | `pnpm run typecheck` / `npm run typecheck` | depends on detected package manager          |

### `app:test`

Unit and integration tests.

| Language   | Command                                             |
| ---------- | --------------------------------------------------- |
| Go         | `CGO_ENABLED=1 go test -count=1 -race -v ./...`     |
| Python     | `uv run pytest --cov=src --cov-report=term-missing` |
| TypeScript | `pnpm test` or `npm test`                           |

---

## How it works

`action.yml` is the public dispatcher. It validates the check, detects the
language(s), and invokes one language-specific composite action:

- `go/action.yml`
- `python/action.yml`
- `typescript/action.yml`

Each language action owns its setup and all format, lint, structural lint,
typecheck, and test commands. Consumers continue to use the root action and do
not need to change their workflow configuration.

For polyglot repositories, the reusable workflow (`quality-gate.yml`) uses
`detect-only` to enumerate all languages, then matrices over them so that
Go, Python, and TypeScript checks run in parallel.

Tool configuration follows this precedence: project configuration is used when
present; the organization configuration is the fallback when the project does
not provide one. Organization fallbacks use strict presets: Ruff selects all
rules, golangci-lint enables all linters, oxlint enables all rules, and ty treats
all rules as errors. Structural lint runs both organization and project rules,
with project rules applied last. The action does not modify project files.

### Tool installation

Binary tools (gofumpt, ast-grep) are downloaded from GitHub releases and verified
against a hardcoded sha256 checksum before execution. This prevents tampered
releases from running on CI runners.

npx-pinned tools (oxfmt, oxlint, react-doctor) are downloaded by npx at the
pinned version. react-doctor runs only when the project declares `react` or
`react-dom`.

Go tools installed via `go install` are pinned by module version (golangci-lint
installed via the official `golangci-lint-action` which pins by version tag).

Most Python tools (ruff, pytest) are installed via uv from the project's
`pyproject.toml` — no additional version pinning in the action itself.
ty and complexipy are the exception: they are installed by the action via
`uvx <tool>@<version>` at a pinned version, independent of the project's own
dependencies, the same way gofumpt and ast-grep are pinned for Go.

### TypeScript package manager detection

The action detects `pnpm-lock.yaml` or `package-lock.json` at the repo root.
If neither is present it exits with an error.

---

## Adding repo-local ast-grep rules

Repositories can define their own structural lint rules alongside the org rules.

1. Create a `sgconfig.yaml` at the project root (or in a `.quality-gate/`
   directory for multi-project repos).
2. Add rule files under `rules/` following the ast-grep rule format.
3. The action picks them up automatically — no configuration needed.

Org rules always run first. Repo-local rules are additive — they extend, never
replace, the org ruleset.

---

## Complete workflow example

Single-language project:

```yaml
name: Quality Gate

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  format:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:format

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:lint

  strlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:strlint

  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:typecheck

  test:
    runs-on: ubuntu-latest
    needs: [format, lint, strlint, typecheck]
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:test
```

Polyglot project (Go + TypeScript, auto-detected):

```yaml
name: Quality Gate

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  format:
    needs: detect
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJson(needs.detect.outputs.languages) }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:format
          language: ${{ matrix.language }}

  lint:
    needs: detect
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJson(needs.detect.outputs.languages) }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:lint
          language: ${{ matrix.language }}

  strlint:
    needs: detect
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJson(needs.detect.outputs.languages) }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:strlint
          language: ${{ matrix.language }}

  typecheck:
    needs: detect
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJson(needs.detect.outputs.languages) }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:typecheck
          language: ${{ matrix.language }}

  test:
    needs: [detect, format, lint, strlint, typecheck]
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ${{ fromJson(needs.detect.outputs.languages) }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:test
          language: ${{ matrix.language }}

  detect:
    runs-on: ubuntu-latest
    outputs:
      languages: ${{ steps.detect.outputs.languages }}
    steps:
      - uses: actions/checkout@v4
      - uses: prefeitura-rio/actions/quality-gate@master
        id: detect
        with:
          check: detect-only
```

Or use the reusable workflow:

```yaml
jobs:
  quality:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: my-project
      working-directory: .
```
