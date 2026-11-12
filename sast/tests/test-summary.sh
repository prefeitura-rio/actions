#!/usr/bin/env bash
# Portable tests for sast/scripts/summary.sh: the scanner tables of the step
# summary, the DefectDojo reimport and the break_on gate. curl is replaced by
# a stub that records its arguments and replays canned JSON, so neither the
# network nor DefectDojo is involved. The script runs under `env -i` with a
# PATH that holds only the stub and the system tools it needs, so a curl
# installed on the host never leaks in.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scripts="$script_dir/../scripts"
summary="$scripts/summary.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- isolated PATH -----------------------------------------------------------

sys_dir="$tmp_dir/sys"
mkdir -p "$sys_dir"
for tool in bash sh cat grep jq tr; do
  resolved=$(command -v "$tool") || {
    printf 'FAIL: required tool %s is not installed\n' "$tool" >&2
    exit 1
  }
  ln -s "$resolved" "$sys_dir/$tool"
done

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"

# curl stub: appends its arguments, one per line and closed by a `--` line,
# to $STUB_LOG_DIR/curl.log and prints the canned response of the URL from
# $CURL_RESPONSES (products.json, reimport.json). A response file that does
# not exist fails the call, as an unreachable server would.
cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env sh
set -eu
: "${STUB_LOG_DIR:?STUB_LOG_DIR required}"
{
  printf '%s\n' "$@"
  printf '%s\n' --
} >>"$STUB_LOG_DIR/curl.log"
url=''
for arg; do
  case "$arg" in
  http://* | https://*) url=$arg ;;
  esac
done
case "$url" in
*/api/v2/products/*) name=products ;;
*/api/v2/reimport-scan/*) name=reimport ;;
*)
  echo "curl stub: unexpected URL $url" >&2
  exit 3
  ;;
esac
response="${CURL_RESPONSES:?CURL_RESPONSES required}/$name.json"
if [ ! -f "$response" ]; then
  echo "curl stub: no response for $url" >&2
  exit 7
fi
cat "$response"
STUB
chmod +x "$stub_dir/curl"

stub_path="$stub_dir:$sys_dir"
log_dir="$tmp_dir/logs"
work_dir="$tmp_dir/work"
out="$tmp_dir/stdout"
err="$tmp_dir/stderr"
status=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [[ -s "$out" ]]; then
    printf -- '--- stdout\n%s\n' "$(<"$out")" >&2
  fi
  if [[ -s "$err" ]]; then
    printf -- '--- stderr\n%s\n' "$(<"$err")" >&2
  fi
  exit 1
}

# reset_work: an empty working directory for the next run.
reset_work() {
  rm -rf "$work_dir"
  mkdir -p "$work_dir"
}

# run_isolated VAR=value... -- script: runs the script in the working
# directory with only the given variables (plus PATH, HOME and STUB_LOG_DIR),
# capturing stdout, stderr and the status. The stub logs start empty.
run_isolated() {
  local assignments=()
  while [[ "$1" != -- ]]; do
    assignments+=("$1")
    shift
  done
  shift
  rm -rf "$log_dir"
  mkdir -p "$log_dir"
  status=0
  (cd "$work_dir" && env -i PATH="$stub_path" HOME="$tmp_dir" STUB_LOG_DIR="$log_dir" \
    "${assignments[@]}" bash "$@") >"$out" 2>"$err" || status=$?
}

assert_status() {
  [[ "$status" == "$1" ]] || fail "$2: expected exit $1, got $status"
}

assert_stdout_contains() {
  [[ "$(<"$out")" == *"$1"* ]] || fail "$2: stdout does not contain '$1'"
}

assert_stdout_lacks() {
  [[ "$(<"$out")" != *"$1"* ]] || fail "$2: stdout unexpectedly contains '$1'"
}

# assert_file <path> <expected content> <context>
assert_file() {
  [[ -f "$1" ]] || fail "$3: $1 does not exist"
  [[ "$(<"$1")" == "$2" ]] || fail "$3: unexpected ${1##*/}:
$(<"$1")
expected:
$2"
}

assert_contains() {
  [[ "$(<"$1")" == *"$2"* ]] || fail "$3: ${1##*/} does not contain '$2':
$(<"$1")"
}

assert_lacks() {
  [[ "$(<"$1")" != *"$2"* ]] || fail "$3: ${1##*/} unexpectedly contains '$2':
$(<"$1")"
}

assert_not_called() {
  [[ ! -e "$log_dir/$1.log" ]] || fail "$2: $1 was called: $(<"$log_dir/$1.log")"
}

# curl_urls: the URL of every curl call of the last run, in order.
curl_urls() {
  [[ -f "$log_dir/curl.log" ]] || return 0
  grep -E '^https?://' "$log_dir/curl.log" || true
}

# curl_arg_count <arg>: how many times the exact argument was passed to curl.
curl_arg_count() {
  [[ -f "$log_dir/curl.log" ]] || {
    printf '0'
    return
  }
  grep -cxF -- "$1" "$log_dir/curl.log" || true
}

assert_curl_arg_count() {
  local actual
  actual=$(curl_arg_count "$1")
  [[ "$actual" == "$2" ]] || fail "$3: curl got '$1' $actual times, expected $2:
$(<"$log_dir/curl.log")"
}

# --- summary.sh: report fixtures -----------------------------------------------

reports="$tmp_dir/reports"
mkdir -p "$reports"
printf '{"runs":[{"tool":{"driver":{"rules":[]}}}]}\n' >"$reports/grype-empty.sarif"
printf '{"results":[]}\n' >"$reports/opengrep-empty.json"

jq -n '{runs: [{tool: {driver: {rules: [{
  id: "CVE-2026-0001",
  help: {text: "Severity: high\nLink: [CVE-2026-0001](https://advisories.test/CVE-2026-0001)\nPackage: libdemo\nVersion: 1.0.0\nFix Version: 1.0.1\nLocation: go.sum\n"},
  properties: {"security-severity": "7.5"}
}]}}}]}' >"$reports/grype.sarif"

jq -n '{results: [
  {check_id: "rules.sqli", path: "app/db.py", start: {line: 12},
   extra: {message: "SQL built from a|b input", severity: "ERROR",
           metadata: {shortlink: "https://rules.test/r/1"}}},
  {check_id: "rules.weak", path: "lib/b.py", start: {line: 3},
   extra: {message: "weak hash", severity: "INFO", metadata: {}}}
]}' >"$reports/opengrep.json"

# Several frameworks matched: a list of reports, one per check_type.
jq -n '[
  {check_type: "terraform", results: {failed_checks: [
    {check_id: "CKV_TF_1", check_name: "Pin module source", resource: "module.vpc",
     file_path: "/main.tf", file_line_range: [3, 9], guideline: "https://docs.test/ckv-tf-1"}]}},
  {check_type: "dockerfile", results: {failed_checks: [
    {check_id: "CKV_DOCKER_2", check_name: "Add a healthcheck", resource: "Dockerfile.",
     file_path: "/Dockerfile", file_line_range: [1, 5]}]}}
]' >"$reports/checkov.json"
printf '{"check_type":"terraform","results":{"failed_checks":[]}}\n' >"$reports/checkov-clean.json"

# use_reports <grype> <opengrep> [checkov]: the scanner reports of the run.
use_reports() {
  cp "$reports/$1" "$work_dir/grype-results.sarif"
  cp "$reports/$2" "$work_dir/opengrep-report.json"
  if [[ -n "${3:-}" ]]; then
    cp "$reports/$3" "$work_dir/checkov-report.json"
  fi
  : >"$work_dir/step-summary.md"
}

step_summary="$work_dir/step-summary.md"
summary_env=(GITHUB_STEP_SUMMARY="$step_summary" CURRENT_BRANCH=main DEFAULT_BRANCH=main
  PRODUCT_NAME=demo ENGAGEMENT_NAME=main)

# --- summary.sh: scanner tables without DefectDojo ------------------------------

reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" -- "$summary"
assert_status 0 'summary without findings'
assert_not_called curl 'summary without findings'
assert_file "$step_summary" '' 'summary without findings'

reset_work
use_reports grype.sarif opengrep.json checkov.json
run_isolated "${summary_env[@]}" ENABLE_CHECKOV=true -- "$summary"
assert_status 0 'summary with scanner findings'
assert_not_called curl 'summary with scanner findings'
assert_contains "$step_summary" '### Dependency Vulnerabilities' 'summary with scanner findings'
assert_contains "$step_summary" \
  '| [CVE-2026-0001](https://advisories.test/CVE-2026-0001) | libdemo | 1.0.0 | 1.0.1 | HIGH (7.5) | go.sum |' \
  'summary with scanner findings'
assert_contains "$step_summary" '### Static Analysis (opengrep)' 'summary with scanner findings'
assert_contains "$step_summary" \
  '| SQL built from a\|b input | app/db.py:12 | [rules.sqli](https://rules.test/r/1) | HIGH |' \
  'summary with scanner findings'
assert_contains "$step_summary" '| weak hash | lib/b.py:3 | rules.weak | LOW |' 'summary with scanner findings'
assert_contains "$step_summary" '### Infrastructure as Code (checkov)' 'summary with scanner findings'
assert_contains "$step_summary" \
  '| [CKV_TF_1](https://docs.test/ckv-tf-1): Pin module source | module.vpc | /main.tf:3 | terraform |' \
  'summary with scanner findings'
assert_contains "$step_summary" '| CKV_DOCKER_2: Add a healthcheck | Dockerfile. | /Dockerfile:1 | dockerfile |' \
  'summary with scanner findings'

reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov-clean.json
run_isolated "${summary_env[@]}" ENABLE_CHECKOV=true -- "$summary"
assert_status 0 'summary with a clean checkov report'
assert_contains "$step_summary" 'No IaC misconfigurations found' 'summary with a clean checkov report'

# checkov disabled: its report is ignored.
reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov.json
run_isolated "${summary_env[@]}" ENABLE_CHECKOV=false -- "$summary"
assert_status 0 'summary with checkov disabled'
assert_lacks "$step_summary" 'checkov' 'summary with checkov disabled'

# --- summary.sh: DefectDojo ------------------------------------------------------

dojo_responses="$tmp_dir/dojo-responses"
mkdir -p "$dojo_responses"
printf '{"count":1,"results":[{"id":3,"name":"demo","prod_type":7}]}\n' >"$dojo_responses/products.json"
printf '{"test":41,"engagement":9}\n' >"$dojo_responses/reimport.json"
dojo_env=(DD_URL=https://dojo.test DD_API_TOKEN=test-dd-token CURL_RESPONSES="$dojo_responses")

# Default branch: opengrep and checkov are reimported into the product type
# of the existing product.
reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov.json
run_isolated "${summary_env[@]}" "${dojo_env[@]}" ENABLE_CHECKOV=true -- "$summary"
assert_status 0 'DefectDojo reimport on the default branch'
[[ "$(curl_urls)" == 'https://dojo.test/api/v2/products/?name=demo
https://dojo.test/api/v2/reimport-scan/
https://dojo.test/api/v2/reimport-scan/' ]] ||
  fail "DefectDojo reimport on the default branch: unexpected curl URLs:
$(curl_urls)"
assert_curl_arg_count 'Authorization: Token test-dd-token' 3 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'scan_type=Semgrep JSON Report' 1 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'file=@opengrep-report.json' 1 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'scan_type=Checkov Scan' 1 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'file=@checkov-report.json' 1 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'product_type=7' 2 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'product_name=demo' 2 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'engagement_name=main' 2 'DefectDojo reimport on the default branch'
assert_curl_arg_count 'close_old_findings=true' 2 'DefectDojo reimport on the default branch'
assert_stdout_contains 'Opengrep scan reimported' 'DefectDojo reimport on the default branch'
assert_stdout_contains 'Checkov scan reimported' 'DefectDojo reimport on the default branch'

# Another branch: nothing goes to DefectDojo.
reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov.json
run_isolated "${summary_env[@]}" "${dojo_env[@]}" ENABLE_CHECKOV=true CURRENT_BRANCH=feature -- "$summary"
assert_status 0 'DefectDojo on another branch'
assert_not_called curl 'DefectDojo on another branch'

# No DefectDojo token: nothing goes to DefectDojo either.
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" DD_URL=https://dojo.test CURL_RESPONSES="$dojo_responses" -- "$summary"
assert_status 0 'DefectDojo without token'
assert_not_called curl 'DefectDojo without token'

# Unknown product: it is created under the Uncategorized product type, and
# checkov is skipped while disabled.
new_product="$tmp_dir/new-product"
mkdir -p "$new_product"
printf '{"count":0,"results":[]}\n' >"$new_product/products.json"
cp "$dojo_responses/reimport.json" "$new_product/reimport.json"
reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov.json
run_isolated "${summary_env[@]}" "${dojo_env[@]}" CURL_RESPONSES="$new_product" ENABLE_CHECKOV=false -- "$summary"
assert_status 0 'DefectDojo with a new product'
assert_stdout_contains 'Creating product on defectdojo' 'DefectDojo with a new product'
assert_curl_arg_count 'product_type_name=Uncategorized' 1 'DefectDojo with a new product'
assert_curl_arg_count 'scan_type=Checkov Scan' 0 'DefectDojo with a new product'

# A rejected reimport is reported without failing the step.
rejected="$tmp_dir/rejected"
mkdir -p "$rejected"
cp "$dojo_responses/products.json" "$rejected/products.json"
printf '{"detail":"Invalid token."}\n' >"$rejected/reimport.json"
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" "${dojo_env[@]}" CURL_RESPONSES="$rejected" -- "$summary"
assert_status 0 'DefectDojo rejected reimport'
assert_stdout_contains 'Error reimporting opengrep to dojo:' 'DefectDojo rejected reimport'
assert_stdout_contains '{"detail":"Invalid token."}' 'DefectDojo rejected reimport'

# --- summary.sh: break_on ----------------------------------------------------------

# A HIGH grype vulnerability breaks the build at HIGH.
reset_work
use_reports grype.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" BREAK_ON=HIGH -- "$summary"
assert_status 1 'grype HIGH with break_on HIGH'
assert_stdout_contains \
  '::error title=SAST::Quality gate met HIGH: 1 dependency vulnerabilities and 0 opengrep findings at or above HIGH' \
  'grype HIGH with break_on HIGH'
assert_contains "$step_summary" '### Dependency Vulnerabilities' 'grype HIGH with break_on HIGH'

# Nothing at or above CRITICAL: grype HIGH and opengrep ERROR (HIGH) pass.
reset_work
use_reports grype.sarif opengrep.json
run_isolated "${summary_env[@]}" BREAK_ON=CRITICAL -- "$summary"
assert_status 0 'HIGH findings with break_on CRITICAL'
assert_stdout_lacks '::error' 'HIGH findings with break_on CRITICAL'

# opengrep ERROR counts as HIGH; at LOW its INFO finding counts too.
reset_work
use_reports grype-empty.sarif opengrep.json
run_isolated "${summary_env[@]}" BREAK_ON=HIGH -- "$summary"
assert_status 1 'opengrep ERROR with break_on HIGH'
assert_stdout_contains '0 dependency vulnerabilities and 1 opengrep findings' 'opengrep ERROR with break_on HIGH'

reset_work
use_reports grype-empty.sarif opengrep.json
run_isolated "${summary_env[@]}" BREAK_ON=LOW -- "$summary"
assert_status 1 'opengrep findings with break_on LOW'
assert_stdout_contains '0 dependency vulnerabilities and 2 opengrep findings' 'opengrep findings with break_on LOW'

# checkov is report-only.
reset_work
use_reports grype-empty.sarif opengrep-empty.json checkov.json
run_isolated "${summary_env[@]}" ENABLE_CHECKOV=true BREAK_ON=LOW -- "$summary"
assert_status 0 'checkov findings with break_on LOW'
assert_contains "$step_summary" '### Infrastructure as Code (checkov)' 'checkov findings with break_on LOW'

# Any other value, such as the action default "-", disables the gate.
reset_work
use_reports grype.sarif opengrep.json
run_isolated "${summary_env[@]}" BREAK_ON=- -- "$summary"
assert_status 0 'findings with break_on -'

# grype failed and left grype-results.sarif empty: the gate still runs.
reset_work
use_reports grype-empty.sarif opengrep-empty.json
: >"$work_dir/grype-results.sarif"
run_isolated "${summary_env[@]}" BREAK_ON=HIGH -- "$summary"
assert_status 0 'empty grype report with break_on HIGH'

printf 'summary script tests passed\n'
