#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

opengrep scan . --sarif-output=all-opengrep-sarif.sarif \
    --json-output=opengrep-report.json \
    --config p/default \
    --config "$GITHUB_ACTION_PATH/opengrep-rules/" \
    --opengrep-ignore-pattern NOSONAR
jq -c '.runs[].results |= map(select((.suppressions // [] | map(.kind == "inSource") | any | not)))' all-opengrep-sarif.sarif >opengrep-sarif.sarif
rm all-opengrep-sarif.sarif
