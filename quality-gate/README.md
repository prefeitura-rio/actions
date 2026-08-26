# Quality-Gate

Language-agnostic composite GitHub Action that runs a single quality check on
any Go, Python, or TypeScript project. Detects the project language automatically
from marker files and executes the appropriate tool for the requested check.

No devenv or Nix dependency is required on the runner.

---

## Using the action

### Input

| Input | Required | Description |
|---|---|---|
| `check` | yes | One of `app:format`, `app:lint`, `app:strlint`, `app:typecheck`, or `app:test` |
| `working-directory` | no | Project path relative to the repository root; defaults to `.` |

The `error_message` output is populated for deterministic action-owned errors,
such as invalid inputs, ambiguous language detection, missing lockfiles, and
checksum failures. Compiler, linter, formatter, and test diagnostics remain in
the normal job log and may leave this output empty.

### Language detection

| Marker file | Detected language |
|---|---|
| `go.mod` | Go |
| `pyproject.toml` | Python |
| `package.json` + `tsconfig.json` | TypeScript |

If none of these marker files exist the action exits with an error. If more
than one language is detected in the same working directory, the action also
fails. Polyglot repositories must invoke the action once per project directory.

---

## Check reference

### `app:format`

Fail on any formatting diff. Never auto-fixes in CI.

| Language | Tool | Version |
|---|---|---|
| Go | gofumpt + goimports | v0.8.0 / v0.35.0 |
| Python | ruff format | via uv (project-pinned) |
| TypeScript | oxfmt | 0.62.0 (via npx) |

### `app:lint`

Static analysis. Runs on all three languages.

| Language | Tool | Version |
|---|---|---|
| Go | golangci-lint | v2.12.2 |
| Python | ruff check + basedpyright | via uv (project-pinned) |
| TypeScript | oxlint | 0.16.7 (via npx) |

### `app:strlint`

Structural lint using ast-grep. Runs in two passes:

1. **Org rules** — bundled with the action, always applied.
2. **Repo-local rules** — loaded from exactly one explicit ast-grep config in the consuming project.

```bash
# Pass 1 — org rules (always runs)
ast-grep scan --config <temporary-config-pointing-to-action-rules>

# Pass 2 — repo-local rules (only if present)
ast-grep scan --config .quality-gate/sgconfig.yaml
```

#### Org rules

| Language | Rule ID | Severity | What it catches |
|---|---|---|---|
| Go | `no-panic` | error | `panic(...)` outside test files |
| Go | `no-http-default-client` | error | `http.DefaultClient`, `http.Get`, `http.Post`, `http.Head`, `http.PostForm` |
| Go | `no-plain-error-wrap` | error | `fmt.Errorf("...: %v", err)` instead of `%w` |
| Python | `no-print` | error | `print(...)` outside test files |
| Python | `no-bare-except` | error | bare `except:` clause (no exception type specified) |
| Python | `no-eval` | error | `eval(...)` and `exec(...)` |
| TypeScript | `no-any-assertion` | error | `expr as any` outside test files |
| TypeScript | `no-console` | error | `console.log`, `.warn`, `.error`, `.info`, `.debug` |

### `app:typecheck`

Type checking and compilation verification.

| Language | Command | Notes |
|---|---|---|
| Go | `go vet ./...` + `go build -o /dev/null` | Builds `./cmd/...` if present, otherwise `.` |
| Python | _(no-op)_ | basedpyright runs inside `app:lint` |
| TypeScript | `pnpm run typecheck` / `npm run typecheck` | depends on detected package manager |

### `app:test`

Unit and integration tests.

| Language | Command |
|---|---|
| Go | `CGO_ENABLED=1 go test -count=1 -race -v ./...` |
| Python | `uv run pytest --cov=src --cov-report=term-missing` |
| TypeScript | `pnpm test` or `npm test` |

---

## How it works

### Tool installation

Binary tools (gofumpt, ast-grep) are downloaded from GitHub releases and verified
against a hardcoded sha256 checksum before execution. This prevents tampered
releases from running on CI runners.

npx-pinned tools (oxfmt, oxlint) are downloaded by npx at the pinned version.

Go tools installed via `go install` are pinned by module version (golangci-lint
installed via the official `golangci-lint-action` which pins by version tag).

Python tools are installed via uv from the project's `pyproject.toml` — no
additional version pinning in the action itself.

### TypeScript package manager detection

For `app:typecheck` and `app:test`, the action detects `pnpm-lock.yaml` or
`package-lock.json` at the project root. If neither is present it exits with an
error. TypeScript projects must also commit `.node-version`; pnpm projects must
declare `packageManager: pnpm@<version>` in `package.json`.

---

## Adding repo-local ast-grep rules

Repositories can define their own structural lint rules alongside the org rules.

1. Create a `.quality-gate/` directory at the repo root (or at the project root
   for multi-project repos).
2. Add a `sgconfig.yaml` inside it:

```yaml
ruleDirs:
  - rules
```

3. Add rule files under `.quality-gate/rules/` following the ast-grep rule format.
4. The action picks up `.quality-gate/sgconfig.yaml` automatically.

The supported config names, in discovery order, are:

```text
.quality-gate/sgconfig.yaml
.quality-gate/sgconfig.yml
sgconfig.yaml
sgconfig.yml
```

Exactly one may exist. A bare `rules/` directory is not enough because ast-grep
needs an explicit config. If `.quality-gate/tests/` exists, the action also runs
the rule tests declared by the `.quality-gate` config.

Org rules always run first. Repo-local rules are additive — they extend, never
replace, the org ruleset.

---

## Polyglot and multi-project repositories

Project names such as `api`, `library`, `cli`, `frontend`, and `backend` are
conventions, not quality-gate inputs. A project is identified by an arbitrary,
stable name and a directory containing exactly one supported language.

Use the reusable workflow once per project:

```yaml
name: Quality Gate

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  payments-api:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: payments-api
      working-directory: services/payments

  shared-library:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: shared-library
      working-directory: libraries/shared

  admin-frontend:
    uses: prefeitura-rio/actions/.github/workflows/quality-gate.yml@master
    with:
      project-name: admin-frontend
      working-directory: applications/admin
```

Each invocation creates the five standard jobs and keeps that project's test
dependency isolated from the other projects. Workflows nested below the
repository root are not executed by GitHub; the caller workflow must live in
the root `.github/workflows/` directory.

`@master` is temporary while the actions release workflow is under development.
Consumers will move to immutable releases when that workflow is available.

---

## Complete workflow example

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
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:format

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:lint

  strlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:strlint

  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:typecheck

  test:
    runs-on: ubuntu-latest
    needs: [format, lint, strlint, typecheck]
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: prefeitura-rio/actions/quality-gate@master
        with:
          check: app:test
```
