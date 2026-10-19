#!/usr/bin/env bash
# Install cosign (root of trust), syft and grype as pinned, checksum- and
# cosign-verified binaries. Versions and checksums match actions/sast.
# Usage: install-scanners.sh [syft] [grype]   (defaults to both)
set -euo pipefail

COSIGN_VERSION="${COSIGN_VERSION:-3.1.1}"
SYFT_VERSION="${SYFT_VERSION:-1.46.0}"
GRYPE_VERSION="${GRYPE_VERSION:-0.115.0}"
BIN="${SCANNER_BIN:-/usr/local/bin}"
DL="$(mktemp -d)"

tools=("$@")
[ "${#tools[@]}" -eq 0 ] && tools=(syft grype)

in_list() { local n="$1"; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

fetch() {
    local name="$1" url="$2" sha="$3" out="$DL/$1" downloaded=1
    if [[ ! -f "$out" ]] || ! echo "$sha  $out" | sha256sum -c --status; then
        curl -sfL "$url" -o "$out"
        downloaded=0
    fi
    if ! echo "$sha  $out" | sha256sum -c --status; then
        echo "checksum mismatch for $name from $url" >&2
        rm -f "$out"
        exit 1
    fi
    return "$downloaded"
}

ensure_cosign() {
    command -v cosign >/dev/null 2>&1 && return 0
    fetch cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
        ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc || true
    install -m 0755 "$DL/cosign" "$BIN/cosign"
}

install_syft() {
    local base="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/"
    if fetch "syft.tar.gz" "${base}syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
        d654f678b709eb53c393d38519d5ed7d2e57205529404018614cfefa0fb2b5ca; then
        fetch syft-checksums.txt.pem "${base}syft_${SYFT_VERSION}_checksums.txt.pem" \
            9cbba2c86a26e4e2ead8d45d6831369dfb63e507b2062605cc108e42946fc029 || true
        fetch syft-checksums.txt.sig "${base}syft_${SYFT_VERSION}_checksums.txt.sig" \
            66711110e4d351b66ad1e8bcae1057dbad1a7d1dfbae57d65c94fb23f59acf49 || true
        fetch syft-checksums.txt "${base}syft_${SYFT_VERSION}_checksums.txt" \
            2fefc202b2eccab83888cc91f5a364a75df0dd777afbbae5b5e23ebd93d81ac6 || true
        cosign verify-blob "$DL/syft-checksums.txt" \
            --certificate "$DL/syft-checksums.txt.pem" \
            --signature "$DL/syft-checksums.txt.sig" \
            --certificate-identity-regexp 'https://github\.com/anchore/syft/\.github/workflows/.+' \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
    fi
    tar -C "$BIN" -xzf "$DL/syft.tar.gz" syft
    chmod +x "$BIN/syft"
}

install_grype() {
    local base="https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/"
    if fetch "grype.tar.gz" "${base}grype_${GRYPE_VERSION}_linux_amd64.tar.gz" \
        3fad92940650e514c0aa2dad83526942a055e210cec09a8a59d9c024adc2b90e; then
        fetch grype-checksums.txt.pem "${base}grype_${GRYPE_VERSION}_checksums.txt.pem" \
            86fd326dea67e29c237fd257fa2dfda127be3192c2ccaeed26b6ebb9bf3387a3 || true
        fetch grype-checksums.txt.sig "${base}grype_${GRYPE_VERSION}_checksums.txt.sig" \
            5048c3b0bee9292c23fe1c19dbd52797b3881683db40689868e937f973ec60a7 || true
        fetch grype-checksums.txt "${base}grype_${GRYPE_VERSION}_checksums.txt" \
            dce654b6f5185d6e4e31cbdd966056562808c0d82b0acc233e9af03e1d4de2b8 || true
        cosign verify-blob "$DL/grype-checksums.txt" \
            --certificate "$DL/grype-checksums.txt.pem" \
            --signature "$DL/grype-checksums.txt.sig" \
            --certificate-identity-regexp 'https://github\.com/anchore/grype/\.github/workflows/.+' \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
    fi
    tar -C "$BIN" -xzf "$DL/grype.tar.gz" grype
    chmod +x "$BIN/grype"
}

ensure_cosign
if in_list syft "${tools[@]}"; then install_syft; fi
if in_list grype "${tools[@]}"; then install_grype; fi
