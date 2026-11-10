#!/usr/bin/env bash
# Portable tests for the SonarQube and DefectDojo scripts of sast/scripts:
# find-sonar-task-id.sh, get-sonar-result.sh and summary.sh. wget and curl are
# replaced by stubs that record their arguments and replay canned JSON, so
# neither the network, SonarQube nor DefectDojo is involved. Every script runs
# under `env -i` with a PATH that holds only the stubs and the system tools
# the scripts need, so a wget or curl installed on the host never leaks in.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scripts="$script_dir/../scripts"
find_task_id="$scripts/find-sonar-task-id.sh"
get_result="$scripts/get-sonar-result.sh"
summary="$scripts/summary.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- isolated PATH -----------------------------------------------------------

sys_dir="$tmp_dir/sys"
mkdir -p "$sys_dir"
for tool in bash sh cat cut find grep head jq rm sleep tr; do
  resolved=$(command -v "$tool") || {
    printf 'FAIL: required tool %s is not installed\n' "$tool" >&2
    exit 1
  }
  ln -s "$resolved" "$sys_dir/$tool"
done

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"

# wget stub: appends its arguments, one per line and closed by a `--` line,
# to $STUB_LOG_DIR/wget.log and writes the canned response of the URL to the
# `-O` file: $WGET_RESPONSES/task.json for /api/ce/task and gate.json for
# /api/qualitygates/project_status. When the URL contains $WGET_FAIL_MATCH it
# leaves the `-O` file empty and exits 8, as wget does on an HTTP error.
cat >"$stub_dir/wget" <<'STUB'
#!/usr/bin/env sh
set -eu
: "${STUB_LOG_DIR:?STUB_LOG_DIR required}"
{
  printf '%s\n' "$@"
  printf '%s\n' --
} >>"$STUB_LOG_DIR/wget.log"
url='' out='' prev=''
for arg; do
  [ "$prev" = -O ] && out=$arg
  case "$arg" in
  http://* | https://*) url=$arg ;;
  esac
  prev=$arg
done
: "${out:?wget stub: -O required}"
if [ -n "${WGET_FAIL_MATCH:-}" ]; then
  case "$url" in
  *"$WGET_FAIL_MATCH"*)
    : >"$out"
    echo "wget stub: forced failure for $url" >&2
    exit 8
    ;;
  esac
fi
case "$url" in
*/api/ce/task\?*) cat "${WGET_RESPONSES:?WGET_RESPONSES required}/task.json" >"$out" ;;
*/api/qualitygates/project_status\?*) cat "${WGET_RESPONSES:?WGET_RESPONSES required}/gate.json" >"$out" ;;
*)
  echo "wget stub: unexpected URL $url" >&2
  exit 1
  ;;
esac
STUB
chmod +x "$stub_dir/wget"

# curl stub: records its arguments like the wget stub and prints the canned
# response of the URL from $CURL_RESPONSES (products.json, reimport.json,
# sonar-page.json, sonar-issues.json, sonar-count.json, hotspots.json). A
# response file that does not exist fails the call, as an unreachable server
# would.
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
*/api/issues/search\?*additionalFields=_all*) name=sonar-page ;;
*/api/issues/search\?*types=VULNERABILITY*) name=sonar-issues ;;
*/api/issues/search\?*) name=sonar-count ;;
*/api/hotspots/search\?*) name=hotspots ;;
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

assert_failed() {
  [[ "$status" != 0 ]] || fail "$1: expected a non-zero exit"
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

assert_absent() {
  [[ ! -e "$1" ]] || fail "$2: ${1##*/} exists"
}

assert_contains() {
  [[ "$(<"$1")" == *"$2"* ]] || fail "$3: ${1##*/} does not contain '$2':
$(<"$1")"
}

assert_lacks() {
  [[ "$(<"$1")" != *"$2"* ]] || fail "$3: ${1##*/} unexpectedly contains '$2':
$(<"$1")"
}

# assert_calls <tool> <expected> <context>: the tool log holds exactly the
# expected calls (arguments one per line, each call closed by `--`).
assert_calls() {
  local log="$log_dir/$1.log" actual
  [[ -f "$log" ]] || fail "$3: $1 was not called"
  actual=$(<"$log")
  [[ "$actual" == "$2" ]] || fail "$3: unexpected $1 calls:
$actual
expected:
$2"
}

assert_not_called() {
  [[ ! -e "$log_dir/$1.log" ]] || fail "$2: $1 was called: $(<"$log_dir/$1.log")"
}

# call <args...>: one expected call in the format of the stub logs.
call() {
  printf '%s\n' "$@" --
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

# --- find-sonar-task-id.sh ---------------------------------------------------

# Without report-task.txt the step still succeeds and publishes an empty
# sonar_task_id, so get-sonar-result.sh reports the missing ID.
reset_work
printf 'previous=1\n' >"$work_dir/github-output"
run_isolated GITHUB_OUTPUT="$work_dir/github-output" -- "$find_task_id"
assert_status 0 'find task ID without report-task.txt'
assert_stdout_contains 'file was not found.' 'find task ID without report-task.txt'
assert_stdout_contains 'Sonar task ID was not found.' 'find task ID without report-task.txt'
assert_stdout_lacks 'Sonar report file:' 'find task ID without report-task.txt'
assert_file "$work_dir/github-output" 'previous=1
sonar_task_id=' 'find task ID without report-task.txt'

# The report is found anywhere below the working directory and only the
# ceTaskId line is read.
reset_work
mkdir -p "$work_dir/build/sonar"
cat >"$work_dir/build/sonar/report-task.txt" <<'EOF'
projectKey=repo:1
serverUrl=https://sonar.test
ceTaskId=AYtask-1
ceTaskUrl=https://sonar.test/api/ce/task?id=AYtask-1
EOF
: >"$work_dir/github-output"
run_isolated GITHUB_OUTPUT="$work_dir/github-output" -- "$find_task_id"
assert_status 0 'find task ID in a nested report-task.txt'
assert_stdout_contains 'Sonar report file: ./build/sonar/report-task.txt' \
  'find task ID in a nested report-task.txt'
assert_stdout_contains 'Sonar task ID: AYtask-1' 'find task ID in a nested report-task.txt'
assert_stdout_lacks 'not found' 'find task ID in a nested report-task.txt'
assert_file "$work_dir/github-output" 'sonar_task_id=AYtask-1' 'find task ID in a nested report-task.txt'

# --- get-sonar-result.sh -----------------------------------------------------

wget_responses="$tmp_dir/wget-responses"
mkdir -p "$wget_responses"
printf '{"task":{"id":"AYtask-1","status":"SUCCESS","analysisId":"AN-1"}}\n' >"$wget_responses/task.json"
printf '{"projectStatus":{"status":"OK"}}\n' >"$wget_responses/gate.json"
sonar_env=(SONAR_HOST_URL=https://sonar.test WGET_RESPONSES="$wget_responses")

# Missing token or task ID: nothing is requested, and the step fails (it runs
# with continue-on-error) without leaving a result file behind.
reset_work
run_isolated "${sonar_env[@]}" SONAR_TASK_ID=AYtask-1 -- "$get_result"
assert_failed 'get result without token'
assert_stdout_contains 'Missing Sonar token.' 'get result without token'
assert_stdout_lacks 'Missing Sonar task ID.' 'get result without token'
assert_stdout_contains 'No Sonar result JSON file created.' 'get result without token'
assert_not_called wget 'get result without token'
assert_absent "$work_dir/sonar.status.json" 'get result without token'
assert_absent "$work_dir/sonar.result.json" 'get result without token'

reset_work
run_isolated "${sonar_env[@]}" SONAR_TOKEN=test-token -- "$get_result"
assert_failed 'get result without task ID'
assert_stdout_contains 'Missing Sonar task ID.' 'get result without task ID'
assert_stdout_lacks 'Missing Sonar token.' 'get result without task ID'
assert_not_called wget 'get result without task ID'
assert_absent "$work_dir/sonar.result.json" 'get result without task ID'

reset_work
run_isolated "${sonar_env[@]}" SONAR_TASK_ID= SONAR_TOKEN= -- "$get_result"
assert_failed 'get result without token and task ID'
assert_stdout_contains 'Missing Sonar task ID.' 'get result without token and task ID'
assert_stdout_contains 'Missing Sonar token.' 'get result without token and task ID'
assert_not_called wget 'get result without token and task ID'

# Success: the task gives the analysis ID, whose quality gate status is kept
# in sonar.result.json for the evidence step.
reset_work
run_isolated "${sonar_env[@]}" SONAR_TASK_ID=AYtask-1 SONAR_TOKEN=test-token -- "$get_result"
assert_status 0 'get result'
assert_calls wget "$(call -X GET '--header=Authorization: Bearer test-token' -O sonar.status.json \
  'https://sonar.test/api/ce/task?id=AYtask-1')
$(call -v -X GET '--header=Authorization: Bearer test-token' -O sonar.result.json \
  'https://sonar.test/api/qualitygates/project_status?analysisId=AN-1')" 'get result'
assert_stdout_contains 'SONAR_ANALYSIS_ID=AN-1' 'get result'
assert_stdout_contains 'GET_RESULT_CODE=0' 'get result'
assert_file "$work_dir/sonar.result.json" '{"projectStatus":{"status":"OK"}}' 'get result'

# A failed quality gate request fails the step and removes the error body, so
# the evidence step does not upload it as a result.
reset_work
run_isolated "${sonar_env[@]}" SONAR_TASK_ID=AYtask-1 SONAR_TOKEN=test-token \
  WGET_FAIL_MATCH=/api/qualitygates/ -- "$get_result"
assert_status 1 'get result with failed quality gate request'
assert_stdout_contains 'GET_RESULT_CODE=8' 'get result with failed quality gate request'
assert_absent "$work_dir/sonar.result.json" 'get result with failed quality gate request'

# A failed task request leaves no analysis ID, so the gate is never queried.
reset_work
run_isolated "${sonar_env[@]}" SONAR_TASK_ID=AYtask-1 SONAR_TOKEN=test-token \
  WGET_FAIL_MATCH=/api/ce/task -- "$get_result"
assert_failed 'get result with failed task request'
assert_stdout_contains 'SONAR_ANALYSIS_ID=' 'get result with failed task request'
assert_stdout_lacks 'SONAR_ANALYSIS_ID=AN-1' 'get result with failed task request'
assert_calls wget "$(call -X GET '--header=Authorization: Bearer test-token' -O sonar.status.json \
  'https://sonar.test/api/ce/task?id=AYtask-1')" 'get result with failed task request'
assert_absent "$work_dir/sonar.result.json" 'get result with failed task request'

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
  PRODUCT_NAME=demo ENGAGEMENT_NAME=main PROJECT_KEY=repo:1 BRANCH_KEY=branch BRANCH_VALUE=main)

# --- summary.sh: scanner tables without SonarQube or DefectDojo ----------------

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
assert_lacks "$step_summary" 'Sonar' 'summary with scanner findings'

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
# of the existing product; without SonarQube its upload is skipped.
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
assert_stdout_contains 'Skipping SonarQube DefectDojo upload' 'DefectDojo reimport on the default branch'

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

# --- summary.sh: SonarQube -------------------------------------------------------

sonar_responses="$tmp_dir/sonar-responses"
mkdir -p "$sonar_responses"
printf '{"total":2}\n' >"$sonar_responses/sonar-count.json"
jq -n '{total: 2, issues: [
  {key: "K1", rule: "python:S2077", severity: "CRITICAL", message: "Sanitize the query",
   component: "repo:1:app/db.py", line: 5},
  {key: "K2", rule: "external_opengrep:rules.sqli", severity: "MEDIUM", message: "Imported twice",
   component: "repo:1:app/db.py", line: 12}
]}' >"$sonar_responses/sonar-issues.json"
printf '{"paging":{"total":0},"hotspots":[]}\n' >"$sonar_responses/hotspots.json"
sonar_summary_env=(SONAR_TOKEN=test-token SONAR_HOST_URL=https://sonar.test
  SONAR_HOST_URL_PUBLIC=https://sonar.public.test CURL_RESPONSES="$sonar_responses")

# A CRITICAL issue breaks the build with break_on CRITICAL; the native issue
# is listed and the SARIF-imported external_* one is not.
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" "${sonar_summary_env[@]}" BREAK_ON=CRITICAL -- "$summary"
assert_status 1 'SonarQube CRITICAL issue with break_on CRITICAL'
assert_stdout_contains '::error title=SAST::Quality gate met CRITICAL' \
  'SonarQube CRITICAL issue with break_on CRITICAL'
assert_contains "$step_summary" '### Sonar Security Findings' 'SonarQube CRITICAL issue with break_on CRITICAL'
assert_contains "$step_summary" \
  '| [Sanitize the query](https://sonar.public.test/project/issues?id=repo:1&open=K1) | app/db.py:5 | python:S2077 |CRITICAL |' \
  'SonarQube CRITICAL issue with break_on CRITICAL'
assert_lacks "$step_summary" 'Imported twice' 'SonarQube CRITICAL issue with break_on CRITICAL'
assert_contains "$step_summary" 'No new security hotspots' 'SonarQube CRITICAL issue with break_on CRITICAL'
assert_contains "$step_summary" \
  '[View all new security issues in SonarQube](https://sonar.public.test/project/issues?id=repo:1&branch=main&types=VULNERABILITY&sinceLeakPeriod=true)' \
  'SonarQube CRITICAL issue with break_on CRITICAL'
assert_curl_arg_count 'test-token:' 3 'SonarQube CRITICAL issue with break_on CRITICAL'
[[ "$(curl_urls)" == 'https://sonar.test/api/issues/search?components=repo:1&branch=main&issueStatuses=OPEN&ps=1
https://sonar.test/api/issues/search?components=repo:1&branch=main&issueStatuses=OPEN&types=VULNERABILITY&ps=200
https://sonar.test/api/hotspots/search?project=repo:1&branch=main&status=TO_REVIEW&ps=200' ]] ||
  fail "SonarQube CRITICAL issue with break_on CRITICAL: unexpected curl URLs:
$(curl_urls)"

# Only a MEDIUM issue: break_on CRITICAL lets the build pass.
medium_only="$tmp_dir/medium-only"
mkdir -p "$medium_only"
cp "$sonar_responses/sonar-count.json" "$sonar_responses/hotspots.json" "$medium_only/"
jq -n '{total: 1, issues: [{key: "K3", rule: "python:S5332", severity: "MEDIUM",
  message: "Use HTTPS", component: "repo:1:app/http.py", line: 7}]}' >"$medium_only/sonar-issues.json"
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" "${sonar_summary_env[@]}" CURL_RESPONSES="$medium_only" BREAK_ON=CRITICAL \
  -- "$summary"
assert_status 0 'SonarQube MEDIUM issue with break_on CRITICAL'
assert_stdout_lacks '::error' 'SonarQube MEDIUM issue with break_on CRITICAL'
assert_contains "$step_summary" 'app/http.py:7 | python:S5332 |MEDIUM |' 'SonarQube MEDIUM issue with break_on CRITICAL'

# No issue and a hotspot to review on a pull request.
clean="$tmp_dir/clean"
mkdir -p "$clean"
printf '{"total":0}\n' >"$clean/sonar-count.json"
printf '{"total":0,"issues":[]}\n' >"$clean/sonar-issues.json"
jq -n '{paging: {total: 1}, hotspots: [{key: "H1", message: "Review this cookie",
  component: "repo:1:web/app.ts", line: 9, securityCategory: "insecure-conf"}]}' >"$clean/hotspots.json"
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" "${sonar_summary_env[@]}" CURL_RESPONSES="$clean" BREAK_ON=LOW \
  BRANCH_KEY=pullRequest BRANCH_VALUE=42 -- "$summary"
assert_status 0 'SonarQube without issues'
assert_contains "$step_summary" 'No new security issues' 'SonarQube without issues'
assert_lacks "$step_summary" '### Sonar Security Findings' 'SonarQube without issues'
assert_contains "$step_summary" '### Security Hotspots (Review Required)' 'SonarQube without issues'
assert_contains "$step_summary" \
  '| [Review this cookie](https://sonar.public.test/security_hotspots?hotspots=H1&pullRequest=42&id=repo:1) | web/app.ts:9 | insecure-conf | ' \
  'SonarQube without issues'

# --- summary.sh: SonarQube issues uploaded to DefectDojo ---------------------------

# On the default branch the native SonarQube vulnerabilities are rebuilt as
# one /api/issues/search payload, without the external_* rules that
# DefectDojo already gets from the opengrep and grype imports.
both="$tmp_dir/both"
mkdir -p "$both"
cp "$dojo_responses/products.json" "$dojo_responses/reimport.json" "$both/"
cp "$medium_only/sonar-count.json" "$medium_only/sonar-issues.json" "$medium_only/hotspots.json" "$both/"
jq -n '{paging: {pageIndex: 1, pageSize: 500, total: 2},
  components: [{key: "repo:1:app/db.py"}, {key: "repo:1:app/db.py"}],
  rules: [{key: "python:S2077"}, {key: "external_opengrep:rules.sqli"}],
  issues: [
    {key: "K1", rule: "python:S2077", severity: "CRITICAL", component: "repo:1:app/db.py"},
    {key: "K2", rule: "external_opengrep:rules.sqli", severity: "MEDIUM", component: "repo:1:app/db.py"}
  ]}' >"$both/sonar-page.json"
reset_work
use_reports grype-empty.sarif opengrep-empty.json
run_isolated "${summary_env[@]}" "${dojo_env[@]}" "${sonar_summary_env[@]}" CURL_RESPONSES="$both" \
  BREAK_ON=CRITICAL -- "$summary"
assert_status 0 'SonarQube issues uploaded to DefectDojo'
assert_stdout_contains 'SonarQube native issues to upload (external_* excluded): 1' \
  'SonarQube issues uploaded to DefectDojo'
assert_stdout_contains 'Sonarqube scan reimported' 'SonarQube issues uploaded to DefectDojo'
assert_curl_arg_count 'scan_type=SonarQube Scan detailed' 1 'SonarQube issues uploaded to DefectDojo'
assert_curl_arg_count 'file=@sonar-issues.json' 1 'SonarQube issues uploaded to DefectDojo'
[[ "$(jq -c '{total, paging, components: [.components[].key], issues: [.issues[].key]}' \
  "$work_dir/sonar-issues.json")" == \
  '{"total":2,"paging":{"pageIndex":1,"pageSize":500,"total":2},"components":["repo:1:app/db.py"],"issues":["K1"]}' ]] ||
  fail "SonarQube issues uploaded to DefectDojo: unexpected sonar-issues.json:
$(<"$work_dir/sonar-issues.json")"
[[ -z "$(cd "$work_dir" && find . -name 'sonar_page_*.json')" ]] ||
  fail 'SonarQube issues uploaded to DefectDojo: the page files were left behind'
[[ "$(curl_urls | grep -c 'additionalFields=_all')" == 1 ]] ||
  fail "SonarQube issues uploaded to DefectDojo: expected one page request:
$(curl_urls)"

printf 'sonar script tests passed\n'
