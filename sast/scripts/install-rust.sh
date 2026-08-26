#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

if ! command -v cargo >/dev/null 2>&1; then
    echo "Installing Rust via rustup..."
    curl https://sh.rustup.rs -sSf | sh -s -- -y
fi

export PATH="$HOME/.cargo/bin:$PATH"
echo "$HOME/.cargo/bin" >>"$GITHUB_PATH"
rustup component add clippy
