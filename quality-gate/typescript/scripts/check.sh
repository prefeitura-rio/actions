#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
QUALITY_GATE_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck disable=SC1091
source "$QUALITY_GATE_ROOT/scripts/lib/diagnostics.sh"
# shellcheck disable=SC1091
source "$QUALITY_GATE_ROOT/scripts/lib/tools.sh"

CHECK=
PROJECT_DIR=.
ACTION_DIR="$SCRIPT_DIR/.."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=${2:?missing value for --check}
      shift 2
      ;;
    --working-directory)
      PROJECT_DIR=${2:?missing value for --working-directory}
      shift 2
      ;;
    --action-directory)
      ACTION_DIR=${2:?missing value for --action-directory}
      shift 2
      ;;
    *)
      qg_error "Unknown argument: $1"
      exit 2
      ;;
  esac
done

PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd)
ACTION_DIR=$(cd -- "$ACTION_DIR" && pwd)
qg_tool_cache_init
cd "$PROJECT_DIR"

MANAGER=
FRAMEWORK=none
REACT=false
HAS_TYPECHECK_SCRIPT=false

load_project_info() {
  local info
  local args=("$SCRIPT_DIR/project-info.js" "$PWD" --check "$CHECK")
  info=$(node "${args[@]}" 2>&1) || {
    qg_error "$info"
    return 1
  }
  while IFS='=' read -r key value; do
    case "$key" in
      manager) MANAGER=$value ;;
      version) : ;;
      framework) FRAMEWORK=$value ;;
      react) REACT=$value ;;
      has_typecheck_script) HAS_TYPECHECK_SCRIPT=$value ;;
    esac
  done <<< "$info"
}

install_dependencies() {
  if [[ "$MANAGER" == npm ]]; then
    npm ci
  else
    pnpm install --frozen-lockfile
  fi
}

prepare_nuxt() {
  [[ "$FRAMEWORK" == nuxt ]] || return 0
  if [[ "$MANAGER" == npm ]]; then
    npm exec --no -- nuxt prepare
  else
    pnpm exec nuxt prepare
  fi
}

format_typescript() {
  local stderr_file files status diff_file file_count
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX")
  local cleanup
  printf -v cleanup 'rm -f -- %q' "$stderr_file"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  if files=$(npx --yes --loglevel=error oxfmt@0.66.0 --list-different . 2>"$stderr_file"); then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -gt 1 || ( "$status" -eq 1 && -z "$files" ) ]]; then
    cat "$stderr_file"
    qg_error "$(cat <<EOF
oxfmt could not complete the formatting check.

Formatter output:
$(cat "$stderr_file")

Fix locally with: npx --yes --loglevel=error oxfmt@0.66.0 --write .
EOF
)"
    rm -f "$stderr_file"
    trap - EXIT
    return "$status"
  fi
  rm -f "$stderr_file"
  trap - EXIT

  if [[ "$status" -eq 0 ]]; then
    echo "oxfmt: all files are correctly formatted."
    return 0
  fi

  file_count=$(printf '%s\n' "$files" | awk 'NF { count++ } END { print count + 0 }')
  diff_file=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX")
  local -a original_files=()
  local -a temp_dirs=()
  local -a temp_files=()

  cleanup_format() {
    rm -f "${diff_file:-}"
    if [[ ${#temp_dirs[@]} -gt 0 ]]; then
      for d in "${temp_dirs[@]}"; do
        rm -rf "$d"
      done
    fi
  }
  trap cleanup_format EXIT

  while IFS= read -r file; do
    [[ -z "$file" || ! -f "$file" ]] && continue
    local temp_dir temp_file
    temp_dir=$(mktemp -d "$(dirname "$file")/.quality-gate-format.XXXXXX")
    temp_file="$temp_dir/$(basename "$file")"
    cp "$file" "$temp_file"
    temp_dirs+=("$temp_dir")
    original_files+=("$file")
    temp_files+=("$temp_file")
  done <<< "$files"

  if [[ ${#temp_files[@]} -gt 0 ]]; then
    local oxfmt_write_err
    oxfmt_write_err=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX")
    if ! npx --yes --loglevel=error oxfmt@0.66.0 --write "${temp_files[@]}" >/dev/null 2>"$oxfmt_write_err"; then
      local write_output
      write_output=$(<"$oxfmt_write_err")
      rm -f "$oxfmt_write_err"
      cleanup_format
      trap - EXIT
      qg_error "$(cat <<EOF
oxfmt could not complete the formatting check.

Formatter output:
$write_output

Fix locally with: npx --yes --loglevel=error oxfmt@0.66.0 --write .
EOF
)"
      return 1
    fi
    rm -f "$oxfmt_write_err"

    for index in "${!temp_files[@]}"; do
      diff -u \
        --label "${original_files[$index]} (current)" \
        --label "${original_files[$index]} (formatted)" \
        "${original_files[$index]}" "${temp_files[$index]}" >> "$diff_file" || true
    done
  fi

  if [[ ! -s "$diff_file" ]]; then
    cleanup_format
    trap - EXIT
    qg_error "$(cat <<EOF
oxfmt could not complete the formatting check.

Fix locally with: npx --yes --loglevel=error oxfmt@0.66.0 --write .
EOF
)"
    return 1
  fi

  cat "$diff_file"
  qg_error "$(cat <<EOF
oxfmt found formatting differences in $file_count file(s).

Files requiring formatting:
$(printf '%s\n' "${original_files[@]}" | while IFS= read -r file; do printf -- '- %s\n' "$file"; done)

Formatting diff:
$(awk 'NR <= 200 { print } NR == 201 { print "... diff truncated; run the command below for the complete result." }' "$diff_file")

Fix locally with: npx --yes --loglevel=error oxfmt@0.66.0 --write .
EOF
)"

  cleanup_format
  trap - EXIT
  echo "oxfmt found formatting differences in $file_count file(s)." >&2
  return 1
}

run_strlint() {
  local tmp_config
  tmp_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate.XXXXXX.yaml")
  local cleanup
  printf -v cleanup 'rm -f -- %q' "$tmp_config"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  cat > "$tmp_config" <<EOF
ruleDirs:
  - ${ACTION_DIR}/rules
languageGlobs:
  html:
    - '*.vue'
languageInjections:
  - hostLanguage: html
    rule:
      pattern: <script>\$\$\$CONTENT</script>
    injected: [javascript, typescript]
  - hostLanguage: html
    rule:
      pattern: <script setup>\$\$\$CONTENT</script>
    injected: [javascript, typescript]
  - hostLanguage: html
    rule:
      pattern: <script lang="\$LANG">\$\$\$CONTENT</script>
    injected: [javascript, typescript]
  - hostLanguage: html
    rule:
      pattern: <script setup lang="\$LANG">\$\$\$CONTENT</script>
    injected: [javascript, typescript]
  - hostLanguage: html
    rule:
      pattern: <script lang="\$LANG" setup>\$\$\$CONTENT</script>
    injected: [javascript, typescript]
EOF
  ast-grep scan --config "$tmp_config"
  rm -f "$tmp_config"
  trap - EXIT
  echo "Org-wide TypeScript ast-grep rules passed."

  if [[ -f sgconfig.yaml || -d rules ]]; then
    ast-grep scan
    echo "Repo-local TypeScript ast-grep rules passed."
  elif [[ -f .quality-gate/sgconfig.yaml ]]; then
    ast-grep scan --config .quality-gate/sgconfig.yaml
    echo "Repo-local TypeScript ast-grep rules passed."
  elif [[ -d .quality-gate/rules ]]; then
    local repo_config
    repo_config=$(mktemp "${TMPDIR:-/tmp}/quality-gate-local.XXXXXX.yaml")
    printf 'ruleDirs:\n  - .quality-gate/rules\n' > "$repo_config"
    ast-grep scan --config "$repo_config"
    rm -f "$repo_config"
    echo "Repo-local TypeScript ast-grep rules passed."
  else
    echo "No repo-local sgconfig.yaml or rules/ found - skipping."
  fi
}

run_typecheck() {
  if [[ "$HAS_TYPECHECK_SCRIPT" == true ]]; then
    if [[ "$MANAGER" == npm ]]; then npm run typecheck; else pnpm run typecheck; fi
  elif [[ "$FRAMEWORK" == vue ]]; then
    if [[ "$MANAGER" == npm ]]; then npm exec --no -- vue-tsc --noEmit; else pnpm exec vue-tsc --noEmit; fi
  elif [[ "$FRAMEWORK" == nuxt ]]; then
    if [[ "$MANAGER" == npm ]]; then npm exec --no -- nuxt typecheck; else pnpm exec nuxt typecheck; fi
  else
    if command -v tsc >/dev/null 2>&1 || [[ -x node_modules/.bin/tsc ]]; then
      if [[ "$MANAGER" == npm ]]; then npm exec --no -- tsc --noEmit; else pnpm exec tsc --noEmit; fi
    else
      qg_error "Missing typecheck script for TypeScript project. Add scripts.typecheck to package.json."
      return 1
    fi
  fi
}

case "$CHECK" in
  app:format)
    format_typescript
    ;;
  app:lint)
    load_project_info
    if [[ -f .oxlintrc.json || -f .oxlintrc.yaml || -f .oxlintrc.yml || -f oxlint.config.js || -f oxlint.config.mjs || -f oxlint.config.ts ]]; then
      npx --yes oxlint@1.81.0 .
    else
      npx --yes oxlint@1.81.0 --config "$ACTION_DIR/.oxlintrc.json" .
    fi
    echo "oxlint: no issues found."
    if [[ "$REACT" == true ]]; then
      npx --yes react-doctor@0.9.12
      echo "react-doctor: no issues found."
    fi
    ;;
  app:strlint)
    qg_install_ast_grep
    run_strlint
    ;;
  app:typecheck)
    load_project_info
    install_dependencies
    prepare_nuxt
    run_typecheck
    ;;
  app:test)
    load_project_info
    install_dependencies
    prepare_nuxt
    if [[ "$MANAGER" == npm ]]; then npm test; else pnpm test; fi
    ;;
  *)
    qg_error "Unknown check: $CHECK"
    exit 2
    ;;
esac
