#!/usr/bin/env bash
# Portable tests for the image scanner scripts of provenance/scripts:
# install-scanners.sh, generate-sbom.sh and scan-image.sh. curl, cosign, syft
# and grype are replaced by stubs that record their arguments, so neither the
# network, a registry nor DefectDojo is involved. Every script runs under
# `env -i` with a PATH that holds only the stubs and the system tools the
# scripts need, so a cosign, syft or grype installed on the host never leaks in.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scripts="$script_dir/../scripts"
install_scanners="$scripts/install-scanners.sh"
generate_sbom="$scripts/generate-sbom.sh"
scan_image="$scripts/scan-image.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- isolated PATH -----------------------------------------------------------

sys_dir="$tmp_dir/sys"
mkdir -p "$sys_dir"
for tool in bash sh mktemp sha256sum install tar gzip chmod rm cat cp mkdir touch tr grep jq; do
  resolved=$(command -v "$tool") || {
    printf 'FAIL: required tool %s is not installed\n' "$tool" >&2
    exit 1
  }
  ln -s "$resolved" "$sys_dir/$tool"
done

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"

# Recording stub shared by cosign, syft and grype: appends its arguments, one
# per line and closed by a `--` line, to $STUB_LOG_DIR/<tool>.log, fails when
# the tool is listed in $STUB_FAIL, and writes the files the scripts read.
cat >"$stub_dir/recorder" <<'STUB'
#!/usr/bin/env sh
set -eu
: "${STUB_LOG_DIR:?STUB_LOG_DIR required}"
tool=${0##*/}
{
  printf '%s\n' "$@"
  printf '%s\n' --
} >>"$STUB_LOG_DIR/$tool.log"
case " ${STUB_FAIL:-} " in
*" $tool "*)
  echo "$tool stub: forced failure" >&2
  exit 1
  ;;
esac
for arg; do
  case "$tool:$arg" in
  syft:cyclonedx-json=*) cat "${SYFT_SBOM:?SYFT_SBOM required}" >"${arg#cyclonedx-json=}" ;;
  grype:sarif=*) printf '{"runs":[]}\n' >"${arg#sarif=}" ;;
  grype:json=*) printf '{"matches":[]}\n' >"${arg#json=}" ;;
  esac
done
if [ "$tool" = grype ]; then
  echo 'grype stub: no vulnerabilities found'
fi
STUB
chmod +x "$stub_dir/recorder"
for tool in cosign syft grype; do
  ln -s recorder "$stub_dir/$tool"
done

# curl stub: records its arguments like the recorder. A download (`-o FILE`)
# copies $CURL_FIXTURES/<last URL segment> when it exists, or writes bytes
# that match no pinned checksum. Any other call is a DefectDojo API call and
# prints $CURL_GET_RESPONSE or, for -X POST, $CURL_POST_RESPONSE.
cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env sh
set -eu
: "${STUB_LOG_DIR:?STUB_LOG_DIR required}"
{
  printf '%s\n' "$@"
  printf '%s\n' --
} >>"$STUB_LOG_DIR/curl.log"
case " ${STUB_FAIL:-} " in
*" curl "*)
  echo "curl stub: forced failure" >&2
  exit 22
  ;;
esac
url='' out='' method=GET prev=''
for arg; do
  case "$prev" in
  -o) out=$arg ;;
  -X) method=$arg ;;
  esac
  case "$arg" in
  http://* | https://*) url=$arg ;;
  esac
  prev=$arg
done
if [ -n "$out" ]; then
  name=${url##*/}
  if [ -n "${CURL_FIXTURES:-}" ] && [ -f "$CURL_FIXTURES/$name" ]; then
    cp "$CURL_FIXTURES/$name" "$out"
  else
    printf 'not the pinned artifact\n' >"$out"
  fi
elif [ "$method" = POST ]; then
  cat "${CURL_POST_RESPONSE:?CURL_POST_RESPONSE required}"
else
  cat "${CURL_GET_RESPONSE:?CURL_GET_RESPONSE required}"
fi
STUB
chmod +x "$stub_dir/curl"

stub_path="$stub_dir:$sys_dir"
# PATH without cosign, for the bootstrap of install-scanners.sh: the scanner
# bin directory comes last so the bootstrapped cosign is found there.
curl_only_dir="$tmp_dir/curl-only"
mkdir -p "$curl_only_dir"
ln -s "$stub_dir/curl" "$curl_only_dir/curl"
log_dir="$tmp_dir/logs"
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

# run_isolated <workdir> <PATH> VAR=value... -- script [args...]: runs the
# script in <workdir> with only the given variables (plus PATH, HOME, TMPDIR
# and STUB_LOG_DIR), capturing stdout, stderr and the status. The stub logs
# start empty on every run.
run_isolated() {
  local workdir="$1" path="$2" assignments=()
  shift 2
  while [[ "$1" != -- ]]; do
    assignments+=("$1")
    shift
  done
  shift
  rm -rf "$log_dir" "$tmp_dir/tmp"
  mkdir -p "$log_dir" "$tmp_dir/tmp" "$workdir"
  status=0
  (cd "$workdir" && env -i PATH="$path" HOME="$tmp_dir" TMPDIR="$tmp_dir/tmp" \
    STUB_LOG_DIR="$log_dir" "${assignments[@]}" "$@") >"$out" 2>"$err" || status=$?
}

assert_status() {
  [[ "$status" == "$1" ]] || fail "$2: expected exit $1, got $status"
}

assert_failed() {
  [[ "$status" != 0 ]] || fail "$1: expected a non-zero exit"
}

assert_stdout_equals() {
  [[ "$(<"$out")" == "$1" ]] || fail "$2: stdout is not '$1'"
}

assert_stdout_contains() {
  [[ "$(<"$out")" == *"$1"* ]] || fail "$2: stdout does not contain '$1'"
}

assert_stdout_lacks() {
  [[ "$(<"$out")" != *"$1"* ]] || fail "$2: stdout unexpectedly contains '$1'"
}

assert_stderr_contains() {
  [[ "$(<"$err")" == *"$1"* ]] || fail "$2: stderr does not contain '$1'"
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

assert_empty_dir() {
  [[ -z "$(ls -A "$1")" ]] || fail "$2: $1 is not empty: $(ls -A "$1")"
}

# assert_downloads <context> <url>...: curl fetched exactly these URLs, in
# order, each with `-sfL <url> -o <file in the script's download dir>`.
assert_downloads() {
  local context="$1" log="$log_dir/curl.log"
  shift
  [[ -f "$log" ]] || fail "$context: curl was not called"
  local -a actual
  mapfile -t actual <"$log"
  local i=0 url
  for url in "$@"; do
    [[ "${actual[i]:-}" == -sfL && "${actual[i + 1]:-}" == "$url" &&
      "${actual[i + 2]:-}" == -o && "${actual[i + 3]:-}" == "$tmp_dir/tmp/"* &&
      "${actual[i + 4]:-}" == -- ]] ||
      fail "$context: download $((i / 5 + 1)) is not '$url':
$(<"$log")"
    i=$((i + 5))
  done
  [[ "${#actual[@]}" == "$i" ]] || fail "$context: unexpected extra curl calls:
$(<"$log")"
}

# --- install-scanners.sh -----------------------------------------------------

cosign_url='https://github.com/sigstore/cosign/releases/download/v3.1.1/cosign-linux-amd64'
syft_base='https://github.com/anchore/syft/releases/download/v1.46.0'
grype_base='https://github.com/anchore/grype/releases/download/v0.115.0'
syft_url="$syft_base/syft_1.46.0_linux_amd64.tar.gz"
grype_url="$grype_base/grype_0.115.0_linux_amd64.tar.gz"
oidc_issuer='https://token.actions.githubusercontent.com'

# Every artifact the script downloads, with the checksum it pins. A version
# bump in install-scanners.sh updates this table too.
pinned=(
  "cosign-linux-amd64 ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc"
  "syft_1.46.0_linux_amd64.tar.gz d654f678b709eb53c393d38519d5ed7d2e57205529404018614cfefa0fb2b5ca"
  "syft_1.46.0_checksums.txt.pem 9cbba2c86a26e4e2ead8d45d6831369dfb63e507b2062605cc108e42946fc029"
  "syft_1.46.0_checksums.txt.sig 66711110e4d351b66ad1e8bcae1057dbad1a7d1dfbae57d65c94fb23f59acf49"
  "syft_1.46.0_checksums.txt 2fefc202b2eccab83888cc91f5a364a75df0dd777afbbae5b5e23ebd93d81ac6"
  "grype_0.115.0_linux_amd64.tar.gz 3fad92940650e514c0aa2dad83526942a055e210cec09a8a59d9c024adc2b90e"
  "grype_0.115.0_checksums.txt.pem 86fd326dea67e29c237fd257fa2dfda127be3192c2ccaeed26b6ebb9bf3387a3"
  "grype_0.115.0_checksums.txt.sig 5048c3b0bee9292c23fe1c19dbd52797b3881683db40689868e937f973ec60a7"
  "grype_0.115.0_checksums.txt dce654b6f5185d6e4e31cbdd966056562808c0d82b0acc233e9af03e1d4de2b8"
)

# The script pins exactly the checksums of the table, each once.
expected_digests=$(for entry in "${pinned[@]}"; do printf '%s\n' "${entry#* }"; done | sort)
script_digests=$(grep -oE '\b[0-9a-f]{64}\b' "$install_scanners" | sort)
[[ "$script_digests" == "$expected_digests" ]] ||
  fail "install-scanners.sh pins other checksums than the test table:
$script_digests"

# expected_verify_blob <tool>: the cosign call that checks a release's
# checksums file against the signing workflow identity of that tool.
expected_verify_blob() {
  local dl="$1" tool="$2"
  call verify-blob "$dl/$tool-checksums.txt" \
    --certificate "$dl/$tool-checksums.txt.pem" \
    --signature "$dl/$tool-checksums.txt.sig" \
    --certificate-identity-regexp "https://github\\.com/anchore/$tool/\\.github/workflows/.+" \
    --certificate-oidc-issuer "$oidc_issuer"
}

# download_dir: the directory the last run downloaded into (the only entry
# of its TMPDIR, created by `mktemp -d`).
download_dir() {
  local entries=("$tmp_dir/tmp"/*)
  [[ "${#entries[@]}" == 1 && -d "${entries[0]}" ]] ||
    fail "expected one download directory in TMPDIR, got: ${entries[*]}"
  printf '%s' "${entries[0]}"
}

scanner_bin="$tmp_dir/scanner-bin"
reset_bin() {
  rm -rf "$scanner_bin"
  mkdir -p "$scanner_bin"
}

# Checksum mismatch: the real script refuses anything but the pinned bytes,
# installs nothing and never reaches the signature check.
reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" -- "$install_scanners"
assert_status 1 'install with tampered syft archive'
assert_stderr_contains "checksum mismatch for syft.tar.gz from $syft_url" \
  'install with tampered syft archive'
assert_downloads 'install with tampered syft archive' "$syft_url"
assert_not_called cosign 'install with tampered syft archive'
assert_empty_dir "$scanner_bin" 'install with tampered syft archive'
[[ -z "$(ls -A "$(download_dir)")" ]] ||
  fail 'install with tampered syft archive: the rejected download was kept'

reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" -- "$install_scanners" grype
assert_status 1 'install grype with tampered archive'
assert_stderr_contains "checksum mismatch for grype.tar.gz from $grype_url" \
  'install grype with tampered archive'
assert_downloads 'install grype with tampered archive' "$grype_url"
assert_not_called cosign 'install grype with tampered archive'
assert_empty_dir "$scanner_bin" 'install grype with tampered archive'

# Without cosign on PATH the script bootstraps it from the pinned release
# first, and refuses a tampered binary.
reset_bin
run_isolated "$tmp_dir" "$curl_only_dir:$sys_dir:$scanner_bin" SCANNER_BIN="$scanner_bin" -- "$install_scanners"
assert_status 1 'install with tampered cosign'
assert_stderr_contains "checksum mismatch for cosign from $cosign_url" 'install with tampered cosign'
assert_downloads 'install with tampered cosign' "$cosign_url"
assert_empty_dir "$scanner_bin" 'install with tampered cosign'

# Overriding the version only changes the URL: the pinned checksum still
# applies, so another release cannot be installed by environment alone.
reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" SYFT_VERSION=9.9.9 \
  -- "$install_scanners" syft
assert_status 1 'install with overridden syft version'
assert_stderr_contains \
  'checksum mismatch for syft.tar.gz from https://github.com/anchore/syft/releases/download/v9.9.9/syft_9.9.9_linux_amd64.tar.gz' \
  'install with overridden syft version'
assert_empty_dir "$scanner_bin" 'install with overridden syft version'

# A failed download fails closed too (the empty file fails the checksum).
reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" STUB_FAIL=curl \
  -- "$install_scanners" syft
assert_status 1 'install with failed download'
assert_stderr_contains 'curl stub: forced failure' 'install with failed download'
assert_stderr_contains "checksum mismatch for syft.tar.gz from $syft_url" 'install with failed download'
assert_empty_dir "$scanner_bin" 'install with failed download'

# Success path. The real artifacts cannot be fetched offline, so it runs a
# copy of the script whose pinned checksums are replaced by those of local
# fixtures; everything else (URLs, verification, extraction) is unchanged.
fixtures="$tmp_dir/fixtures"
mkdir -p "$fixtures/archive"
cp "$stub_dir/recorder" "$fixtures/cosign-linux-amd64"
for tool in syft grype; do
  printf '#!/usr/bin/env sh\necho %s fixture\n' "$tool" >"$fixtures/archive/$tool"
  chmod 0644 "$fixtures/archive/$tool"
done
tar -C "$fixtures/archive" -czf "$fixtures/syft_1.46.0_linux_amd64.tar.gz" syft
tar -C "$fixtures/archive" -czf "$fixtures/grype_0.115.0_linux_amd64.tar.gz" grype
for release in syft_1.46.0 grype_0.115.0; do
  printf '%s checksums\n' "$release" >"$fixtures/${release}_checksums.txt"
  printf '%s certificate\n' "$release" >"$fixtures/${release}_checksums.txt.pem"
  printf '%s signature\n' "$release" >"$fixtures/${release}_checksums.txt.sig"
done

fixture_script="$tmp_dir/install-scanners-fixture.sh"
fixture_source=$(<"$install_scanners")
for entry in "${pinned[@]}"; do
  name=${entry%% *}
  digest=${entry#* }
  [[ "$(grep -c "$digest" "$install_scanners")" == 1 ]] ||
    fail "install-scanners.sh does not pin $name exactly once"
  fixture_digest=$(sha256sum "$fixtures/$name")
  fixture_source=${fixture_source//"$digest"/"${fixture_digest%% *}"}
done
printf '%s\n' "$fixture_source" >"$fixture_script"

reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" CURL_FIXTURES="$fixtures" \
  -- bash "$fixture_script"
assert_status 0 'install syft and grype'
dl=$(download_dir)
assert_downloads 'install syft and grype' \
  "$syft_url" "$syft_base/syft_1.46.0_checksums.txt.pem" \
  "$syft_base/syft_1.46.0_checksums.txt.sig" "$syft_base/syft_1.46.0_checksums.txt" \
  "$grype_url" "$grype_base/grype_0.115.0_checksums.txt.pem" \
  "$grype_base/grype_0.115.0_checksums.txt.sig" "$grype_base/grype_0.115.0_checksums.txt"
assert_calls cosign "$(expected_verify_blob "$dl" syft)
$(expected_verify_blob "$dl" grype)" 'install syft and grype'
for tool in syft grype; do
  [[ -x "$scanner_bin/$tool" ]] || fail "install syft and grype: $tool is not executable"
  [[ "$("$scanner_bin/$tool")" == "$tool fixture" ]] ||
    fail "install syft and grype: $tool is not the archived binary"
done
[[ ! -e "$scanner_bin/cosign" ]] || fail 'install syft and grype: cosign on PATH was reinstalled'

reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" CURL_FIXTURES="$fixtures" \
  -- bash "$fixture_script" syft
assert_status 0 'install syft only'
assert_calls cosign "$(expected_verify_blob "$(download_dir)" syft)" 'install syft only'
[[ "$(ls -A "$scanner_bin")" == syft ]] || fail 'install syft only: installed more than syft'

# Bootstrap: cosign comes from the pinned release, lands in SCANNER_BIN with
# mode 0755 and is the binary that verifies the scanner checksums.
reset_bin
run_isolated "$tmp_dir" "$curl_only_dir:$sys_dir:$scanner_bin" SCANNER_BIN="$scanner_bin" CURL_FIXTURES="$fixtures" \
  -- bash "$fixture_script" grype
assert_status 0 'install grype with cosign bootstrap'
assert_downloads 'install grype with cosign bootstrap' "$cosign_url" \
  "$grype_url" "$grype_base/grype_0.115.0_checksums.txt.pem" \
  "$grype_base/grype_0.115.0_checksums.txt.sig" "$grype_base/grype_0.115.0_checksums.txt"
assert_calls cosign "$(expected_verify_blob "$(download_dir)" grype)" \
  'install grype with cosign bootstrap'
[[ -n "$(find "$scanner_bin/cosign" -perm 0755)" ]] ||
  fail 'install grype with cosign bootstrap: cosign is not installed with mode 0755'
[[ -x "$scanner_bin/grype" ]] || fail 'install grype with cosign bootstrap: grype is not installed'

# A rejected signature stops the installation of that tool before extraction.
for tool in syft grype; do
  reset_bin
  run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" CURL_FIXTURES="$fixtures" \
    STUB_FAIL=cosign -- bash "$fixture_script" "$tool"
  assert_failed "install $tool with rejected signature"
  assert_stderr_contains 'cosign stub: forced failure' "install $tool with rejected signature"
  assert_calls cosign "$(expected_verify_blob "$(download_dir)" "$tool")" \
    "install $tool with rejected signature"
  assert_empty_dir "$scanner_bin" "install $tool with rejected signature"
done

# A tampered checksums file is rejected even though its fetch is `|| true`.
tampered="$tmp_dir/fixtures-tampered"
cp -r "$fixtures" "$tampered"
printf 'forged checksums\n' >"$tampered/syft_1.46.0_checksums.txt"
reset_bin
run_isolated "$tmp_dir" "$stub_path" SCANNER_BIN="$scanner_bin" CURL_FIXTURES="$tampered" \
  -- bash "$fixture_script" syft
assert_status 1 'install with tampered checksums file'
assert_stderr_contains \
  "checksum mismatch for syft-checksums.txt from $syft_base/syft_1.46.0_checksums.txt" \
  'install with tampered checksums file'
assert_not_called cosign 'install with tampered checksums file'
assert_empty_dir "$scanner_bin" 'install with tampered checksums file'

# --- generate-sbom.sh --------------------------------------------------------

image_digest='ghcr.io/prefeitura-rio/example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
sbom_fixture="$tmp_dir/sbom-fixture.json"
cat >"$sbom_fixture" <<'JSON'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": [
    { "name": "openssl", "bom-ref": "pkg:deb/debian/openssl@3.0.15?arch=amd64", "purl": "pkg:deb/debian/openssl@3.0.15" },
    { "name": "zlib", "purl": "pkg:apk/alpine/zlib@1.3.1" }
  ]
}
JSON

sbom_dir="$tmp_dir/sbom"
run_isolated "$sbom_dir" "$stub_path" IMAGE_DIGEST="$image_digest" SYFT_SBOM="$sbom_fixture" \
  -- "$generate_sbom"
assert_status 0 'sbom'
assert_stdout_equals image-sbom.cdx.json 'sbom'
assert_calls syft "$(call "$image_digest" -o cyclonedx-json=image-sbom.cdx.json)" 'sbom'
[[ "$(<"$sbom_fixture")" == "$(<"$sbom_dir/image-sbom.cdx.json")" ]] ||
  fail 'sbom: the SBOM file does not hold the syft output'

mkdir -p "$sbom_dir/out"
run_isolated "$sbom_dir" "$stub_path" IMAGE_DIGEST="$image_digest" SYFT_SBOM="$sbom_fixture" \
  SBOM_FILE=out/custom.cdx.json -- "$generate_sbom"
assert_status 0 'sbom with SBOM_FILE'
assert_stdout_equals out/custom.cdx.json 'sbom with SBOM_FILE'
assert_calls syft "$(call "$image_digest" -o cyclonedx-json=out/custom.cdx.json)" 'sbom with SBOM_FILE'

for image in empty unset; do
  if [[ "$image" == unset ]]; then
    run_isolated "$sbom_dir" "$stub_path" SYFT_SBOM="$sbom_fixture" -- "$generate_sbom"
  else
    run_isolated "$sbom_dir" "$stub_path" IMAGE_DIGEST= SYFT_SBOM="$sbom_fixture" -- "$generate_sbom"
  fi
  assert_failed "sbom with $image IMAGE_DIGEST"
  assert_stderr_contains 'IMAGE_DIGEST required' "sbom with $image IMAGE_DIGEST"
  assert_not_called syft "sbom with $image IMAGE_DIGEST"
  assert_stdout_lacks cdx.json "sbom with $image IMAGE_DIGEST"
done

run_isolated "$sbom_dir" "$stub_path" IMAGE_DIGEST="$image_digest" SYFT_SBOM="$sbom_fixture" \
  STUB_FAIL=syft -- "$generate_sbom"
assert_failed 'sbom with syft failure'
assert_stderr_contains 'syft stub: forced failure' 'sbom with syft failure'
assert_stdout_lacks cdx.json 'sbom with syft failure'

# --- scan-image.sh -----------------------------------------------------------

dd_url='https://defectdojo.example.invalid'
dd_token='dd-test-token'
products_found="$tmp_dir/products-found.json"
products_missing="$tmp_dir/products-missing.json"
reimport_ok="$tmp_dir/reimport-ok.json"
reimport_error="$tmp_dir/reimport-error.json"
printf '{"count":1,"results":[{"id":3,"name":"example","prod_type":7}]}\n' >"$products_found"
printf '{"count":0,"results":[]}\n' >"$products_missing"
printf '{"test":11,"engagement":5}\n' >"$reimport_ok"
printf '{"detail":"stub: rejected"}\n' >"$reimport_error"

scan_env=(IMAGE_DIGEST="$image_digest" SYFT_SBOM="$sbom_fixture")
dd_env=(
  DD_URL="$dd_url"
  DD_API_TOKEN="$dd_token"
  PRODUCT_NAME=example
  ENGAGEMENT_NAME=ci
  CURRENT_BRANCH=main
  DEFAULT_BRANCH=main
  CURL_GET_RESPONSE="$products_found"
  CURL_POST_RESPONSE="$reimport_ok"
)
expected_scan_syft=$(call "$image_digest" -o cyclonedx-json=image-cdx.json)
expected_scan_grype=$(call sbom:image-cdx.json -o table -o sarif=image-grype.sarif -o json=image-grype.json)

# expected_reimport <scan type> <file> <title> <product type parameter>
expected_reimport() {
  call -s -X POST "$dd_url/api/v2/reimport-scan/" \
    -H "Authorization: Token $dd_token" \
    -H 'Content-Type: multipart/form-data' \
    -F active=true -F verified=true -F "scan_type=$1" \
    -F product_name=example -F engagement_name=ci -F "test_title=$3" \
    -F tags=image -F tags=container -F "file=@$2" -F "$4" \
    -F auto_create_context=true -F close_old_findings=true
}

expected_products_lookup=$(call -s -X GET "$dd_url/api/v2/products/?name=example" \
  -H "Authorization: Token $dd_token")

scan_dir="$tmp_dir/scan"
reset_scan_dir() {
  rm -rf "$scan_dir"
  mkdir -p "$scan_dir"
}

# Without DefectDojo settings the scan runs and uploads nothing.
reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" -- "$scan_image"
assert_status 0 'scan without DefectDojo'
assert_calls syft "$expected_scan_syft" 'scan without DefectDojo'
assert_calls grype "$expected_scan_grype" 'scan without DefectDojo'
assert_not_called curl 'scan without DefectDojo'
assert_stdout_contains 'grype stub: no vulnerabilities found' 'scan without DefectDojo'
for report in image-cdx.json image-grype.sarif image-grype.json; do
  [[ -f "$scan_dir/$report" ]] || fail "scan without DefectDojo: $report was not written"
done
[[ ! -e "$scan_dir/image-bom-info.json" ]] || fail 'scan without DefectDojo: inventory was built'

# Uploads happen only on the default branch, with both DefectDojo settings.
for skip in branch url token; do
  reset_scan_dir
  case "$skip" in
  branch) run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" CURRENT_BRANCH=feature -- "$scan_image" ;;
  url) run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" DD_URL= -- "$scan_image" ;;
  token) run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" DD_API_TOKEN= -- "$scan_image" ;;
  esac
  assert_status 0 "scan without upload ($skip)"
  assert_calls grype "$expected_scan_grype" "scan without upload ($skip)"
  assert_not_called curl "scan without upload ($skip)"
done

# Default branch: the product type is resolved, then the SBOM inventory and
# the grype findings are reimported, tagged image/container.
reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" -- "$scan_image"
assert_status 0 'scan with upload'
assert_calls curl "$expected_products_lookup
$(expected_reimport 'CycloneDX Scan' image-bom-info.json 'Image SBOM (syft)' product_type=7)
$(expected_reimport 'Anchore Grype' image-grype.json 'Image Vulnerabilities (grype)' product_type=7)" \
  'scan with upload'
assert_stdout_contains 'Reimported: Image SBOM (syft)' 'scan with upload'
assert_stdout_contains 'Reimported: Image Vulnerabilities (grype)' 'scan with upload'
jq -e '.vulnerabilities == [
    {
      id: "INFO-openssl",
      source: { name: "Not-A-Vuln" },
      ratings: [ { severity: "info", method: "other" } ],
      description: "Image package inventory entry.",
      affects: [ { ref: "pkg:deb/debian/openssl@3.0.15?arch=amd64" } ]
    },
    {
      id: "INFO-zlib",
      source: { name: "Not-A-Vuln" },
      ratings: [ { severity: "info", method: "other" } ],
      description: "Image package inventory entry.",
      affects: [ { ref: "pkg:apk/alpine/zlib@1.3.1" } ]
    }
  ] and (.components | length) == 2' "$scan_dir/image-bom-info.json" >/dev/null ||
  fail "scan with upload: unexpected inventory: $(<"$scan_dir/image-bom-info.json")"

# An unknown product is created under the Uncategorized product type.
reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" \
  CURL_GET_RESPONSE="$products_missing" -- "$scan_image"
assert_status 0 'scan with upload of a new product'
assert_calls curl "$expected_products_lookup
$(expected_reimport 'CycloneDX Scan' image-bom-info.json 'Image SBOM (syft)' product_type_name=Uncategorized)
$(expected_reimport 'Anchore Grype' image-grype.json 'Image Vulnerabilities (grype)' product_type_name=Uncategorized)" \
  'scan with upload of a new product'

# A rejected reimport is reported but, like actions/sast, does not fail the
# scan: the vulnerability reports are already written.
reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" \
  CURL_POST_RESPONSE="$reimport_error" -- "$scan_image"
assert_status 0 'scan with rejected reimport'
assert_stderr_contains "Error reimporting 'Image SBOM (syft)' to DefectDojo:" 'scan with rejected reimport'
assert_stderr_contains "Error reimporting 'Image Vulnerabilities (grype)' to DefectDojo:" \
  'scan with rejected reimport'
assert_stderr_contains 'stub: rejected' 'scan with rejected reimport'
assert_stdout_lacks 'Reimported:' 'scan with rejected reimport'

# Failures of the scanners stop the script before anything is uploaded.
reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" STUB_FAIL=syft -- "$scan_image"
assert_failed 'scan with syft failure'
assert_stderr_contains 'syft stub: forced failure' 'scan with syft failure'
assert_not_called grype 'scan with syft failure'
assert_not_called curl 'scan with syft failure'

reset_scan_dir
run_isolated "$scan_dir" "$stub_path" "${scan_env[@]}" "${dd_env[@]}" STUB_FAIL=grype -- "$scan_image"
assert_failed 'scan with grype failure'
assert_stderr_contains 'grype stub: forced failure' 'scan with grype failure'
assert_not_called curl 'scan with grype failure'

for image in empty unset; do
  reset_scan_dir
  if [[ "$image" == unset ]]; then
    run_isolated "$scan_dir" "$stub_path" SYFT_SBOM="$sbom_fixture" "${dd_env[@]}" -- "$scan_image"
  else
    run_isolated "$scan_dir" "$stub_path" IMAGE_DIGEST= SYFT_SBOM="$sbom_fixture" "${dd_env[@]}" -- "$scan_image"
  fi
  assert_failed "scan with $image IMAGE_DIGEST"
  assert_stderr_contains 'IMAGE_DIGEST required' "scan with $image IMAGE_DIGEST"
  assert_not_called syft "scan with $image IMAGE_DIGEST"
  assert_not_called grype "scan with $image IMAGE_DIGEST"
  assert_not_called curl "scan with $image IMAGE_DIGEST"
done

printf 'provenance scanner script tests passed\n'
