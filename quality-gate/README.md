# Quality-Gate

Language-agnostic composite GitHub Action that runs a single quality check on
any Go, Python, or TypeScript project. Detects the project language automatically
from marker files and executes the appropriate tool for the requested check.

No devenv or Nix dependency is required on the runner.

---

## Using the action

### Input

| Input | Required | Valid values |
|---|---|---|
| `check` | yes | `app:format` · `app:lint` · `app:strlint` · `app:typecheck` · `app:test` |

### Language detection

| Marker file | Detected language |
|---|---|
| `go.mod` | Go |
| `pyproject.toml` or `setup.py` | Python |
| `package.json` + `tsconfig.json` | TypeScript |

If none of these marker files exist the action exits with an error.

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
2. **Repo-local rules** — detected at runtime from a `.quality-gate/` directory or root `sgconfig.yaml` in the consuming repo.

```bash
# Pass 1 — org rules (always runs)
ast-grep scan --config <action-path>/<lang>/rules

# Pass 2 — repo-local rules (only if present)
ast-grep scan   # uses repo's own sgconfig.yaml
```

#### Org rules

| Language | Rule ID | Severity | What it catches |
|---|---|---|---|
| Go | `no-panic` | error | `panic(...)` outside test files |
| Go | `no-http-default-client` | warning | `http.DefaultClient`, `http.Get`, `http.Post`, `http.Head`, `http.PostForm` |
| Go | `no-plain-error-wrap` | warning | `fmt.Errorf("...: %v", err)` instead of `%w` |
| Python | `no-print` | warning | `print(...)` outside test files |
| Python | `no-bare-except` | warning | bare `except:` clause (no exception type specified) |
| Python | `no-eval` | error | `eval(...)` and `exec(...)` |
| TypeScript | `no-any-assertion` | error | `expr as any` outside test files |
| TypeScript | `no-console` | warning | `console.log`, `.warn`, `.error`, `.info`, `.debug` |

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

The action detects `pnpm-lock.yaml` or `package-lock.json` at the repo root.
If neither is present it exits with an error.

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
4. The action picks them up automatically — no configuration needed.

Org rules always run first. Repo-local rules are additive — they extend, never
replace, the org ruleset.

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
