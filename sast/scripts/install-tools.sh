#!/usr/bin/env bash
set -euo pipefail

# Downloads $2 to $TOOL_DL/$1 unless a copy matching the pinned sha256 $3
# is already there (i.e. restored from cache). Returns 0 when it downloaded,
# 1 when the cached copy was reused, so callers can skip signature checks on
# cache hits. The sha256 verification below runs either way, so a poisoned
# cache entry never survives.
fetch() {
  local name="$1" url="$2" sha="$3" out="$TOOL_DL/$1" downloaded=1
  if [[ ! -f "$out" ]] || ! echo "$sha  $out" | sha256sum -c --status; then
    curl -sfL "$url" -o "$out"
    downloaded=0
  fi
  # Hard exit, not "set -e": callers invoke fetch in an if-condition, which
  # disables errexit inside the function, so a mismatch must abort explicitly.
  if ! echo "$sha  $out" | sha256sum -c --status; then
    echo "::error title=SAST::checksum mismatch for $name from $url"
    rm -f "$out"
    exit 1
  fi
  return $downloaded
}

# cosign (pinned sha256 only: it is the root of trust for the others)
fetch cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
  ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc || true
install -m 0755 "$TOOL_DL/cosign" "$TOOL_BIN/cosign"

# opengrep
if fetch opengrep "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/opengrep_manylinux_x86" \
  1f06548af379ab6080698a609612890ffad2d92dc2172f1e97d38d48096d5ef8; then
  fetch opengrep.sig "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/opengrep_manylinux_x86.sig" \
    61b2beb453f965c0f37c799964fa5cbe556bd9042141a7b44e8dcd01e9eab56e || true
  fetch opengrep.cert "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/opengrep_manylinux_x86.cert" \
    9eba8a14e840790e1e7b456e2b7b83a63ad7f1b6b3fd46989881db64c87755b0 || true
  "$TOOL_BIN/cosign" verify-blob \
    --cert "$TOOL_DL/opengrep.cert" \
    --signature "$TOOL_DL/opengrep.sig" \
    --certificate-identity-regexp "https://github.com/opengrep/opengrep.+" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$TOOL_DL/opengrep"
fi
install -m 0755 "$TOOL_DL/opengrep" "$TOOL_BIN/opengrep"

# syft
SYFT_BASE_URL="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/"
if fetch "syft.tar.gz" "${SYFT_BASE_URL}syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
  d654f678b709eb53c393d38519d5ed7d2e57205529404018614cfefa0fb2b5ca; then
  fetch syft-checksums.txt.pem "${SYFT_BASE_URL}syft_${SYFT_VERSION}_checksums.txt.pem" \
    9cbba2c86a26e4e2ead8d45d6831369dfb63e507b2062605cc108e42946fc029 || true
  fetch syft-checksums.txt.sig "${SYFT_BASE_URL}syft_${SYFT_VERSION}_checksums.txt.sig" \
    66711110e4d351b66ad1e8bcae1057dbad1a7d1dfbae57d65c94fb23f59acf49 || true
  fetch syft-checksums.txt "${SYFT_BASE_URL}syft_${SYFT_VERSION}_checksums.txt" \
    2fefc202b2eccab83888cc91f5a364a75df0dd777afbbae5b5e23ebd93d81ac6 || true
  "$TOOL_BIN/cosign" verify-blob "$TOOL_DL/syft-checksums.txt" \
    --certificate "$TOOL_DL/syft-checksums.txt.pem" \
    --signature "$TOOL_DL/syft-checksums.txt.sig" \
    --certificate-identity-regexp 'https://github\.com/anchore/syft/\.github/workflows/.+' \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
fi
tar -C "$TOOL_BIN" -xzf "$TOOL_DL/syft.tar.gz" syft
chmod +x "$TOOL_BIN/syft"

# grype
GRYPE_BASE_URL="https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/"
if fetch "grype.tar.gz" "${GRYPE_BASE_URL}grype_${GRYPE_VERSION}_linux_amd64.tar.gz" \
  3fad92940650e514c0aa2dad83526942a055e210cec09a8a59d9c024adc2b90e; then
  fetch grype-checksums.txt.pem "${GRYPE_BASE_URL}grype_${GRYPE_VERSION}_checksums.txt.pem" \
    86fd326dea67e29c237fd257fa2dfda127be3192c2ccaeed26b6ebb9bf3387a3 || true
  fetch grype-checksums.txt.sig "${GRYPE_BASE_URL}grype_${GRYPE_VERSION}_checksums.txt.sig" \
    5048c3b0bee9292c23fe1c19dbd52797b3881683db40689868e937f973ec60a7 || true
  fetch grype-checksums.txt "${GRYPE_BASE_URL}grype_${GRYPE_VERSION}_checksums.txt" \
    dce654b6f5185d6e4e31cbdd966056562808c0d82b0acc233e9af03e1d4de2b8 || true
  "$TOOL_BIN/cosign" verify-blob "$TOOL_DL/grype-checksums.txt" \
    --certificate "$TOOL_DL/grype-checksums.txt.pem" \
    --signature "$TOOL_DL/grype-checksums.txt.sig" \
    --certificate-identity-regexp 'https://github\.com/anchore/grype/\.github/workflows/.+' \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
fi
tar -C "$TOOL_BIN" -xzf "$TOOL_DL/grype.tar.gz" grype
chmod +x "$TOOL_BIN/grype"

# checkov (venv lives in the cached dir, so a cache hit skips pip entirely)
if [[ "$ENABLE_CHECKOV" == "true" ]]; then
  if [[ "$("$TOOL_DIR/venv/bin/checkov" --version 2>/dev/null || true)" != "$CHECKOV_VERSION" ]]; then
    rm -rf "$TOOL_DIR/venv"
    python3 -m venv "$TOOL_DIR/venv"
    "$TOOL_DIR/venv/bin/pip" install --quiet --disable-pip-version-check "checkov==${CHECKOV_VERSION}"
  fi
  ln -sf "$TOOL_DIR/venv/bin/checkov" "$TOOL_BIN/checkov"

  # See sast/patches/fix_checkov_module_finder.py: checkov's terraform
  # module_finder builds excluded_paths_regex by joining the *repr of the
  # whole excluded_paths list* character-by-character instead of joining
  # the patterns, so --skip-path silently over-matches with one entry and
  # frequently crashes checkov outright (re.error: nothing to repeat) with
  # more. The "Run checkov" step derives --skip-path from the normalized
  # ignore file, so this must be patched for --skip-path to be usable at
  # all. Verified against the installed source; fails loudly if a
  # checkov_version bump changes the surrounding code, rather than
  # silently shipping a crash-prone --skip-path.
  MODULE_FINDER_PATH=$("$TOOL_DIR/venv/bin/python3" -c \
    "import importlib.util, os; print(os.path.join(os.path.dirname(importlib.util.find_spec('checkov').origin), 'terraform', 'module_loading', 'module_finder.py'))")
  python3 "$GITHUB_ACTION_PATH/patches/fix_checkov_module_finder.py" "$MODULE_FINDER_PATH"
fi
