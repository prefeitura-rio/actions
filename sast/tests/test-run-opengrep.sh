#!/usr/bin/env bash
# Portable tests for scripts/run-opengrep.sh. opengrep is a stub that records
# its arguments and writes the SARIF and JSON reports, so no registry, network
# or real scanner is involved. Checks that the script:
# - scans with p/default and the rules of opengrep-rules/;
# - excludes the p/default rule github-actions-mutable-action-tag (under the
#   id the registry serves and the short id of semgrep-rules), which
#   opengrep-rules/ci/ replaces with a copy that exempts prefeitura-rio/actions;
# - drops in-source (NOSONAR) suppressions from the SARIF it uploads.
# Also checks that Quality Gate Tests installs the opengrep version and
# sha256 the action pins, for test-opengrep-rules.sh.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner="$script_dir/../scripts/run-opengrep.sh"
action_path=$(cd -- "$script_dir/.." && pwd)

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null || fail 'jq is not installed'

stub_dir="$tmp_dir/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/opengrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_LOG"
for arg in "$@"; do
  case "$arg" in
  --sarif-output=*)
    cat >"${arg#--sarif-output=}" <<'SARIF'
{"runs":[{"results":[{"ruleId":"kept"},{"ruleId":"suppressed","suppressions":[{"kind":"inSource"}]}]}]}
SARIF
    ;;
  --json-output=*) printf '{"results":[]}\n' >"${arg#--json-output=}" ;;
  esac
done
STUB
chmod +x "$stub_dir/opengrep"

work_dir="$tmp_dir/work"
mkdir -p "$work_dir"
stub_log="$tmp_dir/opengrep.args"

(
  cd "$work_dir"
  PATH="$stub_dir:$PATH" STUB_LOG="$stub_log" GITHUB_ACTION_PATH="$action_path" bash "$runner"
) || fail 'run-opengrep.sh exited non-zero'

mapfile -t args <"$stub_log"

# has_pair <flag> <value>: the stub received <flag> immediately followed by <value>.
has_pair() {
  local i
  for ((i = 0; i + 1 < ${#args[@]}; i++)); do
    [[ "${args[i]}" == "$1" && "${args[i + 1]}" == "$2" ]] && return 0
  done
  return 1
}

[[ "${args[0]}" == scan ]] || fail "opengrep subcommand is ${args[0]}, expected scan"
has_pair --config p/default || fail 'p/default is not scanned'
has_pair --config "$action_path/opengrep-rules/" || fail 'opengrep-rules/ is not scanned'
has_pair --exclude-rule yaml.github-actions.security.github-actions-mutable-action-tag.github-actions-mutable-action-tag ||
  fail 'the registry id of github-actions-mutable-action-tag is not excluded'
has_pair --exclude-rule yaml.github-actions.security.github-actions-mutable-action-tag ||
  fail 'the semgrep-rules id of github-actions-mutable-action-tag is not excluded'
has_pair --opengrep-ignore-pattern NOSONAR || fail 'NOSONAR is not the ignore pattern'

excluded=$(grep -c '^--exclude-rule$' "$stub_log" || true)
[[ "$excluded" == 2 ]] || fail "expected 2 --exclude-rule, got $excluded"

grep -q 'id: ci-github-actions-mutable-action-tag$' "$action_path/opengrep-rules/ci/pipeline-hardening.yaml" ||
  fail 'opengrep-rules/ci/ does not ship the replacement rule ci-github-actions-mutable-action-tag'

[[ -f "$work_dir/opengrep-sarif.sarif" ]] || fail 'opengrep-sarif.sarif was not written'
[[ ! -e "$work_dir/all-opengrep-sarif.sarif" ]] || fail 'all-opengrep-sarif.sarif was not removed'
kept=$(jq -r '[.runs[].results[].ruleId] | join(",")' "$work_dir/opengrep-sarif.sarif")
[[ "$kept" == kept ]] || fail "SARIF keeps [$kept], expected only the unsuppressed result"

# The Quality Gate Tests job that runs test-opengrep-rules.sh installs the
# opengrep the action pins.
workflow="$script_dir/../../.github/workflows/quality-gate-tests.yml"
pinned_version=$(sed -n 's/^OPENGREP_VERSION=//p' "$script_dir/../scripts/prepare-tool-cache.sh")
ci_version=$(sed -n 's/^ *OPENGREP_VERSION: //p' "$workflow")
ci_sha=$(sed -n 's/^ *OPENGREP_SHA256: //p' "$workflow")
[[ -n "$pinned_version" && "$ci_version" == "$pinned_version" ]] ||
  fail "Quality Gate Tests installs opengrep $ci_version, the action pins $pinned_version"
if [[ ! "$ci_sha" =~ ^[0-9a-f]{64}$ ]] || ! grep -q "$ci_sha" "$script_dir/../scripts/install-tools.sh"; then
  fail "Quality Gate Tests checks opengrep against sha256 $ci_sha, which install-tools.sh does not pin"
fi

echo 'PASS: run-opengrep.sh'
