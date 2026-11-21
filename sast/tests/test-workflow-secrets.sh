#!/usr/bin/env bash
# Portable tests for the reusable workflow .github/workflows/sast.yml. Every
# secret it declares under on.workflow_call.secrets, except the obsolete ones
# (description starting with "Obsoleto"), must be an input of sast/action.yml
# and must reach the action: the `Run SAST` step passes it in `with:` as
# `<name>: ${{ secrets.<name> }}`. Without that, the ts_* secrets a caller
# passes never get to `Tailscale connect`, and DefectDojo is never reached.
# The files are read with awk (no YAML parser needed).

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workflow="$script_dir/../../.github/workflows/sast.yml"
action="$script_dir/../action.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# declared_secrets: prints "<name> <obsolete 0|1>" for each secret of
# on.workflow_call.secrets.
declared_secrets() {
  awk '
    /^on:/ { in_on = 1; next }
    /^[^ #]/ { in_on = 0 }
    !in_on { next }
    /^  workflow_call:/ { in_call = 1; next }
    /^  [^ ]/ { in_call = 0 }
    !in_call { next }
    /^    secrets:/ { in_secrets = 1; next }
    /^    [^ ]/ { in_secrets = 0 }
    !in_secrets { next }
    /^      [a-z_]+:$/ {
      if (name != "") print name, obsolete
      name = substr($1, 1, length($1) - 1)
      obsolete = 0
      next
    }
    /^        description: / {
      sub(/^ *description: */, "")
      if ($0 ~ /^Obsoleto/) obsolete = 1
    }
    END { if (name != "") print name, obsolete }
  ' "$workflow"
}

# run_sast_with: prints the `key: value` lines of the `with:` block of the
# job step named `Run SAST`.
run_sast_with() {
  awk '
    /^      - name: / { in_step = (substr($0, 15) == "Run SAST"); in_with = 0; next }
    !in_step { next }
    /^        with:$/ { in_with = 1; next }
    /^        [^ ]/ { in_with = 0 }
    in_with && /^          [a-z_]+: / {
      sub(/^ +/, "")
      print
    }
  ' "$workflow"
}

# action_inputs: prints the input names of sast/action.yml.
action_inputs() {
  awk '
    /^inputs:/ { in_inputs = 1; next }
    /^[^ ]/ { in_inputs = 0 }
    in_inputs && /^  [a-z_]+:$/ { print substr($1, 1, length($1) - 1) }
  ' "$action"
}

[[ "$(grep -c '^      - name: Run SAST$' "$workflow")" == "1" ]] ||
  fail "expected exactly one step named 'Run SAST' in $workflow"
grep -A3 '^      - name: Run SAST$' "$workflow" | grep -q 'uses: \$/sast$' ||
  fail "'Run SAST' does not use the local sast action"

secrets=$(declared_secrets)
with_lines=$(run_sast_with)
inputs=$(action_inputs)
[[ -n "$secrets" ]] || fail "no secret found under on.workflow_call.secrets"
[[ -n "$with_lines" ]] || fail "'Run SAST' has no with: entries"

# The Tailscale and DefectDojo secrets must be declared, active, passed on.
for required in dd_token ts_tags ts_oauth_client_id ts_oauth_secret; do
  grep -qx "$required 0" <<<"$secrets" ||
    fail "secret $required is not declared (or is marked obsolete)"
done

checked=0
while read -r name obsolete; do
  [[ "$obsolete" == "1" ]] && continue
  grep -qx "$name" <<<"$inputs" ||
    fail "secret $name is not an input of sast/action.yml"
  expected="$name: \${{ secrets.$name }}"
  grep -qxF "$expected" <<<"$with_lines" ||
    fail "'Run SAST' does not pass secret $name ('$expected' missing in with:)"
  checked=$((checked + 1))
done <<<"$secrets"

printf 'PASS: sast.yml passes its %d active secrets to the sast action\n' "$checked"
