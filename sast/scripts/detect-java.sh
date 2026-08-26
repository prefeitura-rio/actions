#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

if find . -maxdepth 2 -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" | grep -q .; then
    echo "found=true" >>"$GITHUB_OUTPUT"
else
    echo "found=false" >>"$GITHUB_OUTPUT"
fi
