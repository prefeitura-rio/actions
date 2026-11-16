#!/usr/bin/env bash
# Checks that the reusable workflows (on: workflow_call) of this repository
# resolve their own actions and scripts at the commit the caller pinned, so
# pinning a reusable workflow by tag or SHA also pins what it runs.
#
# Rejected in a reusable workflow:
#   - a step "uses: prefeitura-rio/actions/<path>@<ref>" not guarded by
#     "if: endsWith(job.workflow_ref, '@refs/heads/master')" (use "$/<path>");
#   - "repository: prefeitura-rio/actions" (use job.workflow_repository);
#   - "ref: master" or "ref: main" (use job.workflow_sha);
#   - "refs/heads/master" outside that guard (derive it from job.workflow_ref).

set -euo pipefail

workflows_dir="${1:-.github/workflows}"

if [[ ! -d "$workflows_dir" ]]; then
  echo "check-reusable-workflow-refs: directory not found: $workflows_dir" >&2
  exit 2
fi

shopt -s nullglob
status=0
for file in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
  grep -Eq '^[[:space:]]*workflow_call:' "$file" || continue
  awk -v file="$file" '
    function report(line_number, message) {
      printf "%s:%d: %s\n", file, line_number, message
      failed = 1
    }
    function check_step() {
      if (step_uses_line && !step_guarded) {
        report(step_uses_line, "internal action pinned to a mutable ref; use \"$/<path>\" or guard the step with if: endsWith(job.workflow_ref, '\''@refs/heads/master'\'')")
      }
      step_uses_line = 0
      step_guarded = 0
    }
    BEGIN { guard = "endsWith(job.workflow_ref, '\''@refs/heads/master'\'')" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]/ { check_step() }
    {
      guard_position = index($0, guard)
      if (guard_position) {
        # A negated guard ("!endsWith(...)") selects the non-master callers.
        if (substr($0, guard_position - 1, 1) != "!") {
          step_guarded = 1
        }
        next
      }
      if ($0 ~ /uses:[[:space:]]*["'\'']?prefeitura-rio\/actions\//) {
        step_uses_line = NR
      }
      if ($0 ~ /repository:[[:space:]]*["'\'']?prefeitura-rio\/actions["'\'']?[[:space:]]*$/) {
        report(NR, "checkout of this repository by name; use repository: ${{ job.workflow_repository }}")
      }
      if ($0 ~ /[[:space:]]ref:[[:space:]]*["'\'']?(master|main)["'\'']?[[:space:]]*$/) {
        report(NR, "checkout of a mutable branch; use ref: ${{ job.workflow_sha }}")
      }
      if (index($0, "refs/heads/master")) {
        report(NR, "hardcoded refs/heads/master; derive it from job.workflow_ref")
      }
    }
    END {
      check_step()
      exit failed
    }
  ' "$file" || status=1
done

exit "$status"
