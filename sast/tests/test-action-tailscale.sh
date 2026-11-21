#!/usr/bin/env bash
# Portable tests for the Tailscale steps of sast/action.yml. Dependabot runs
# get no Actions secrets, so ts_oauth_client_id and ts_oauth_secret arrive
# empty there: the `Tailscale connect` step must then be skipped (instead of
# failing the job) and a notice step must say why. The test reads the steps
# with awk (no YAML parser needed), checks that the two credential inputs are
# optional and evaluates both `if:` conditions for every combination of empty
# and filled credentials, translated to bash after a strict grammar check.
# It also checks the wiring for runner containers without TUN: the
# ts_networking input, the networking step, its tailscaled-args and DD_PROXY.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
action="$script_dir/../action.yml"

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

# step_if <name>: prints the `if:` expression of the step named <name>.
step_if() {
  local block
  block=$(step_block "$1") || fail "expected exactly one step named '$1'"
  sed -n 's/^      if: //p' <<<"$block"
}

# input_field <input> <field>: prints a field of an input of the action.
input_field() {
  awk -v input="$1" -v field="$2" '
    /^inputs:/ { in_inputs = 1; next }
    /^[^ ]/ { in_inputs = 0 }
    !in_inputs { next }
    /^  [a-z_]+:$/ { current = substr($1, 1, length($1) - 1); next }
    current == input && $1 == field ":" {
      sub(/^ *[a-z_]+: */, "")
      print
    }
  ' "$action"
}

# eval_if <expression> <client id> <secret>: exit 0 when the expression is
# true for those input values. Only `inputs.<name> ==|!= ''` comparisons
# joined by && or || are accepted, so nothing else reaches eval.
eval_if() {
  local expr="$1" client_id="$2" secret="$3"
  local term="inputs\.ts_oauth_(client_id|secret) (==|!=) ''"
  [[ "$expr" =~ ^$term(\ (\&\&|\|\|)\ $term)*$ ]] ||
    fail "unexpected condition grammar: $expr"
  local translated
  # shellcheck disable=SC2016 # the variable names are expanded later, by eval
  translated=$(sed \
    -e 's/inputs\.ts_oauth_client_id/"$client_id"/g' \
    -e 's/inputs\.ts_oauth_secret/"$secret"/g' \
    -e "s/''/\"\"/g" <<<"$expr")
  eval "[[ $translated ]]"
}

connect_if=$(step_if "Tailscale connect")
skip_if=$(step_if "Skip Tailscale without credentials")
[[ -n "$connect_if" ]] || fail "'Tailscale connect' has no if: condition"
[[ -n "$skip_if" ]] || fail "'Skip Tailscale without credentials' has no if: condition"

step_block "Tailscale connect" | grep -q 'uses: tailscale/github-action@' ||
  fail "'Tailscale connect' does not use tailscale/github-action"
step_block "Skip Tailscale without credentials" | grep -q 'echo "::notice' ||
  fail "'Skip Tailscale without credentials' does not print a ::notice::"
step_block "Skip Tailscale without credentials" | grep -q 'DefectDojo' ||
  fail "the notice does not say that DefectDojo will not be reached"

# The notice step comes first, so the notice is the first line of the log.
first_step=$(awk '/^runs:/ { r = 1 } r && /^    - name: / { print substr($0, 13); exit }' "$action")
[[ "$first_step" == "Skip Tailscale without credentials" ]] ||
  fail "the first step is '$first_step', expected the notice step"

for input in ts_oauth_client_id ts_oauth_secret; do
  [[ "$(input_field "$input" required)" == "false" ]] ||
    fail "input $input must be required: false"
  [[ "$(input_field "$input" default)" == '""' ]] ||
    fail "input $input must default to an empty string"
done

# Runner containers without TUN (iplanrio-runners): the networking step runs
# with the connection, its tailscaled arguments reach the Tailscale action
# and its proxy reaches both DefectDojo upload steps.
[[ "$(input_field ts_networking required)" == "false" ]] ||
  fail "input ts_networking must be required: false"
[[ "$(input_field ts_networking default)" == '"auto"' ]] ||
  fail "input ts_networking must default to auto"
networking_if=$(step_if "Pick Tailscale networking")
[[ "$networking_if" == "$connect_if" ]] ||
  fail "'Pick Tailscale networking' must run exactly when 'Tailscale connect' does"
networking=$(step_block "Pick Tailscale networking")
grep -qx '      id: ts_networking' <<<"$networking" ||
  fail "'Pick Tailscale networking' must have id: ts_networking"
# shellcheck disable=SC2016 # a literal ${{ }} expression of action.yml
grep -qxF '        TS_NETWORKING: ${{ inputs.ts_networking }}' <<<"$networking" ||
  fail "'Pick Tailscale networking' does not get inputs.ts_networking"
grep -qF 'scripts/tailscale-networking.sh' <<<"$networking" ||
  fail "'Pick Tailscale networking' does not run tailscale-networking.sh"
step_names=$(awk '/^runs:/ { r = 1 } r && /^    - name: / { print substr($0, 13) }' "$action")
grep -A1 -x 'Pick Tailscale networking' <<<"$step_names" | grep -qx 'Tailscale connect' ||
  fail "'Pick Tailscale networking' must come right before 'Tailscale connect'"
# shellcheck disable=SC2016 # a literal ${{ }} expression of action.yml
step_block "Tailscale connect" |
  grep -qxF '        tailscaled-args: ${{ steps.ts_networking.outputs.tailscaled_args }}' ||
  fail "'Tailscale connect' does not pass the picked tailscaled-args"
for step in "Run Vulnerability scan & collect sbom" "Showing issues to summary"; do
  block=$(step_block "$step") || fail "expected exactly one step named '$step'"
  # shellcheck disable=SC2016 # a literal ${{ }} expression of action.yml
  grep -qxF '        DD_PROXY: ${{ steps.ts_networking.outputs.proxy }}' <<<"$block" ||
    fail "'$step' does not get the Tailscale proxy as DD_PROXY"
done

# client id, secret, expected connect (1 runs, 0 skipped)
cases=(
  "id|secret|1"
  "id||0"
  "|secret|0"
  "||0"
)
for case in "${cases[@]}"; do
  IFS='|' read -r client_id secret expected <<<"$case"
  connect=0
  skip=0
  eval_if "$connect_if" "$client_id" "$secret" && connect=1
  eval_if "$skip_if" "$client_id" "$secret" && skip=1
  label="client_id='${client_id}' secret='${secret}'"
  [[ "$connect" == "$expected" ]] ||
    fail "$label: Tailscale connect runs=$connect, expected $expected"
  [[ "$skip" == "$((1 - expected))" ]] ||
    fail "$label: notice step runs=$skip, expected $((1 - expected))"
done

printf 'PASS: sast/action.yml skips Tailscale without both OAuth credentials and wires its networking mode\n'
