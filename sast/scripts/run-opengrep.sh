#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

# p/default flags every mutable "uses:" ref, including the
# prefeitura-rio/actions@master/@latest refs this repository's README tells
# consumers to use. opengrep-rules/ci/ ships ci-github-actions-mutable-action-tag,
# a copy that exempts only prefeitura-rio/actions, so the registry rule is
# excluded here. Both ids are listed: the registry serves the rule under the
# path-qualified id, and semgrep-rules declares it under the short one.
opengrep scan . --sarif-output=all-opengrep-sarif.sarif \
    --json-output=opengrep-report.json \
    --config p/default \
    --config "$GITHUB_ACTION_PATH/opengrep-rules/" \
    --exclude-rule yaml.github-actions.security.github-actions-mutable-action-tag.github-actions-mutable-action-tag \
    --exclude-rule yaml.github-actions.security.github-actions-mutable-action-tag \
    --opengrep-ignore-pattern NOSONAR
jq -c '.runs[].results |= map(select((.suppressions // [] | map(.kind == "inSource") | any | not)))' all-opengrep-sarif.sarif >opengrep-sarif.sarif
rm all-opengrep-sarif.sarif
