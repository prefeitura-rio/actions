#!/usr/bin/env bash
# Portable tests for what sast/action.yml needs from the runner image, so it
# also works on the ARC runners of the organization (iplanrio-runners), whose
# image sets no locale and ships a python3 without ensurepip:
# - scripts/pick-python.sh keeps the python3 on PATH when it creates a venv
#   and otherwise asks setup-python for 3.12; python3 is a stub, so no
#   interpreter of the host is involved;
# - it turns the pip cache of setup-python on only when a file of the
#   workspace matches its default cache-dependency-path (**/requirements.txt,
#   then **/pyproject.toml), because setup-python fails with `cache: pip` and
#   no such file, as in a Node repository;
# - the action passes that version and cache to setup-python and runs the
#   scanner steps under the C.UTF-8 locale (opengrep reads its UTF-8 rules
#   with the locale encoding).

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
action="$script_dir/../action.yml"
picker="$script_dir/../scripts/pick-python.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# step_block <name>: prints the step of runs.steps named <name>, from its
# `- name:` line up to the next step.
step_block() {
  awk -v name="$1" '
    /^runs:/ { in_runs = 1; next }
    !in_runs { next }
    /^    - name: / {
      found = (substr($0, 13) == name)
      if (found) count++
    }
    found { print }
    END { if (count != 1) exit 1 }
  ' "$action"
}

# step_names: the steps of the action, in order.
step_names() {
  awk '/^runs:/ { r = 1 } r && /^    - name: / { print substr($0, 13) }' "$action"
}

# --- pick-python.sh ----------------------------------------------------------

sys_dir="$tmp_dir/sys"
mkdir -p "$sys_dir"
for tool in bash find mktemp rm; do
  resolved=$(command -v "$tool") || fail "required tool $tool is not installed"
  ln -s "$resolved" "$sys_dir/$tool"
done

# python3 stub: records its arguments; `-m venv <dir>` creates <dir> and
# exits with $VENV_STATUS, as a python3 without ensurepip exits 1.
stub_dir="$tmp_dir/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
if [[ "$1 $2" == "-m venv" ]]; then
  mkdir -p "$3"
  [[ "$VENV_STATUS" == 0 ]] || echo "The virtual environment was not created successfully because ensurepip is not available." >&2
  exit "$VENV_STATUS"
fi
exit 2
STUB
chmod +x "$stub_dir/python3"

out="$tmp_dir/stdout"
output="$tmp_dir/github-output"
stub_log="$tmp_dir/python3.log"

# run_picker <PATH> <venv status> [<workspace>]: the workspace defaults to
# one with a requirements.txt, as most Python consumers have.
default_workspace="$tmp_dir/ws-requirements"
mkdir -p "$default_workspace"
: >"$default_workspace/requirements.txt"
run_picker() {
  : >"$output"
  : >"$stub_log"
  local status=0
  env -i PATH="$1" GITHUB_OUTPUT="$output" GITHUB_WORKSPACE="${3:-$default_workspace}" \
    STUB_LOG="$stub_log" VENV_STATUS="$2" TMPDIR="$tmp_dir" bash "$picker" >"$out" 2>&1 || status=$?
  [[ "$status" == 0 ]] || fail "pick-python.sh exited $status: $(<"$out")"
}

# output_line <key>: the value pick-python.sh wrote for <key>; fails unless
# it wrote exactly one.
output_line() {
  local lines
  lines=$(grep -c "^$1=" "$output" || true)
  [[ "$lines" == 1 ]] || fail "pick-python.sh wrote $lines '$1=' lines: $(<"$output")"
  sed -n "s/^$1=//p" "$output"
}

run_picker "$stub_dir:$sys_dir" 0
[[ "$(output_line version)" == '' ]] || fail "python3 with venv: unexpected output $(<"$output")"
[[ "$(<"$out")" != *'::notice'* ]] || fail 'python3 with venv: printed a notice'
[[ "$(<"$stub_log")" == "-m venv $tmp_dir/"*/venv ]] ||
  fail "python3 with venv: unexpected python3 call $(<"$stub_log")"

run_picker "$stub_dir:$sys_dir" 1
[[ "$(output_line version)" == '3.12' ]] || fail "python3 without ensurepip: unexpected output $(<"$output")"
[[ "$(<"$out")" == *'::notice title=SAST Python::'* ]] || fail 'python3 without ensurepip: no notice'
[[ "$(<"$out")" != *'ensurepip is not available.'* ]] || fail 'python3 without ensurepip: venv error leaked to the log'

run_picker "$sys_dir" 0
[[ "$(output_line version)" == '3.12' ]] || fail "no python3 on PATH: unexpected output $(<"$output")"

# Pip cache: on with a file that setup-python's default
# cache-dependency-path matches anywhere in the workspace, off otherwise.
ws="$tmp_dir/ws"
mkdir -p "$ws/empty" "$ws/node/src" "$ws/nested/services/api" "$ws/pyproject/pkg" \
  "$ws/hidden/.ci" "$ws/link" "$ws/broken" "$ws/dirname/requirements.txt"
: >"$ws/node/package.json"
: >"$ws/node/src/requirements.txt.bak"
: >"$ws/nested/services/api/requirements.txt"
: >"$ws/pyproject/pkg/pyproject.toml"
: >"$ws/hidden/.ci/requirements.txt"
: >"$tmp_dir/outside-requirements.txt"
ln -s "$tmp_dir/outside-requirements.txt" "$ws/link/requirements.txt"
ln -s "$tmp_dir/missing-requirements.txt" "$ws/broken/requirements.txt"

# expect_cache <workspace> <venv status> <expected cache> <case>
expect_cache() {
  run_picker "$stub_dir:$sys_dir" "$2" "$1"
  [[ "$(output_line cache)" == "$3" ]] || fail "$4: expected cache '$3', got $(<"$output")"
}

for venv in 0 1; do
  expect_cache "$default_workspace" "$venv" pip "requirements.txt at the root (venv $venv)"
  expect_cache "$ws/empty" "$venv" '' "empty workspace (venv $venv)"
  expect_cache "$ws/node" "$venv" '' "Node workspace without Python dependency files (venv $venv)"
  expect_cache "$ws/nested" "$venv" pip "nested requirements.txt (venv $venv)"
  expect_cache "$ws/pyproject" "$venv" pip "pyproject.toml only (venv $venv)"
  expect_cache "$ws/hidden" "$venv" pip "requirements.txt in a hidden directory (venv $venv)"
  expect_cache "$ws/link" "$venv" pip "requirements.txt symlinked to a file (venv $venv)"
  expect_cache "$ws/broken" "$venv" '' "broken requirements.txt symlink (venv $venv)"
  expect_cache "$ws/dirname" "$venv" '' "directory named requirements.txt (venv $venv)"
done

run_picker "$stub_dir:$sys_dir" 1 "$ws/node"
[[ "$(<"$out")" == *'::notice title=SAST Python cache::'* ]] ||
  fail 'Python 3.12 without dependency files: no notice that the pip cache is off'
run_picker "$stub_dir:$sys_dir" 0 "$ws/node"
[[ "$(<"$out")" != *'::notice'* ]] || fail 'python3 on PATH without dependency files: printed a notice'

run_picker "$stub_dir:$sys_dir" 1 "$tmp_dir/missing-workspace"
[[ "$(output_line cache)" == '' ]] || fail "missing workspace: expected the cache off, got $(<"$output")"

leftover=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -name 'tmp.*')
[[ -z "$leftover" ]] || fail "pick-python.sh left its probe directory behind: $leftover"

# --- action wiring -----------------------------------------------------------

mapfile -t steps < <(step_names)
pick_index=-1
setup_index=-1
for i in "${!steps[@]}"; do
  [[ "${steps[$i]}" == 'Pick Python' ]] && pick_index=$i
  [[ "${steps[$i]}" == 'Setup environment' ]] && setup_index=$i
done
((pick_index >= 0 && setup_index == pick_index + 1)) ||
  fail "'Pick Python' must come right before 'Setup environment'"

pick=$(step_block 'Pick Python') || fail "expected exactly one 'Pick Python' step"
grep -qx '      id: python' <<<"$pick" || fail "'Pick Python' must have id: python"
grep -qx '      if: always()' <<<"$pick" || fail "'Pick Python' must run with if: always()"
grep -qF 'scripts/pick-python.sh' <<<"$pick" || fail "'Pick Python' does not run pick-python.sh"

setup=$(step_block 'Setup environment') || fail "expected exactly one 'Setup environment' step"
# shellcheck disable=SC2016 # a literal ${{ }} expression of action.yml
grep -qxF '        python-version: ${{ steps.python.outputs.version }}' <<<"$setup" ||
  fail "'Setup environment' does not take the version picked by 'Pick Python'"
# shellcheck disable=SC2016 # a literal ${{ }} expression of action.yml
grep -qxF '        cache: ${{ steps.python.outputs.cache }}' <<<"$setup" ||
  fail "'Setup environment' does not take the pip cache picked by 'Pick Python'"
[[ $(grep -c '^        cache:' <<<"$setup") == 1 ]] || fail "'Setup environment' sets cache more than once"

for step in 'Install scanner tools' 'Run opengrep' 'Run checkov (IaC)'; do
  block=$(step_block "$step") || fail "expected exactly one step named '$step'"
  for var in LANG LC_ALL; do
    grep -qx "        $var: C.UTF-8" <<<"$block" || fail "'$step' does not set $var: C.UTF-8"
  done
done

printf 'PASS: sast/action.yml sets up Python and the UTF-8 locale on any runner\n'
