#!/usr/bin/env bash
# Portable tests for sast/scripts/tailscale-networking.sh, which picks between
# the kernel TUN device and tailscaled userspace networking. The TUN device
# and /proc/self/status are replaced through TS_TUN_DEVICE and TS_PROC_STATUS:
# /dev/null stands for a usable character device, a missing path for a
# container without /dev/net/tun, and fake status files hold the capability
# bounding set, so no TUN device or capability of the host is involved.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
picker="$script_dir/../scripts/tailscale-networking.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

out="$tmp_dir/stdout"
output="$tmp_dir/github-output"
status=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [[ -s "$out" ]] && printf -- '--- stdout\n%s\n' "$(<"$out")" >&2
  [[ -s "$output" ]] && printf -- '--- GITHUB_OUTPUT\n%s\n' "$(<"$output")" >&2
  exit 1
}

# CAP_NET_ADMIN is bit 12: 000001ffffffffff is the full set of a GitHub-hosted
# runner, 00000000a80425fb the default set of a container runtime (no
# NET_ADMIN), 0000000000001000 NET_ADMIN alone.
status_file() {
  printf 'Name:\tbash\nCapInh:\t0000000000000000\nCapBnd:\t%s\nCapAmb:\t0000000000000000\n' "$2" >"$tmp_dir/$1"
  printf '%s' "$tmp_dir/$1"
}
full_caps=$(status_file full 000001ffffffffff)
container_caps=$(status_file container 00000000a80425fb)
net_admin_only=$(status_file net-admin 0000000000001000)
garbage_caps=$(status_file garbage 'not-hex')
no_capbnd="$tmp_dir/no-capbnd"
printf 'Name:\tbash\n' >"$no_capbnd"
regular_file="$tmp_dir/regular-file"
: >"$regular_file"
missing="$tmp_dir/missing"

# run_picker <mode> <tun device> <proc status>
run_picker() {
  : >"$output"
  status=0
  env -i PATH="$PATH" GITHUB_OUTPUT="$output" TS_NETWORKING="$1" \
    TS_TUN_DEVICE="$2" TS_PROC_STATUS="$3" bash "$picker" >"$out" 2>&1 || status=$?
}

expect_tun() {
  [[ "$status" == 0 ]] || fail "$1: exit $status"
  [[ "$(<"$output")" == $'mode=tun\ntailscaled_args=\nproxy=' ]] ||
    fail "$1: expected tun outputs"
  [[ "$(<"$out")" != *'::notice'* ]] || fail "$1: tun mode prints a notice"
}

expect_userspace() {
  [[ "$status" == 0 ]] || fail "$1: exit $status"
  [[ "$(<"$output")" == $'mode=userspace\ntailscaled_args=--tun=userspace-networking --socks5-server=localhost:1055\nproxy=socks5h://localhost:1055' ]] ||
    fail "$1: expected userspace outputs"
  [[ "$(<"$out")" == *'::notice title=Tailscale userspace networking::'* ]] ||
    fail "$1: userspace mode prints no notice"
}

run_picker auto /dev/null "$full_caps"
expect_tun 'auto with a TUN device and NET_ADMIN (GitHub-hosted runner)'

run_picker auto /dev/null "$net_admin_only"
expect_tun 'auto with a TUN device and NET_ADMIN alone'

run_picker auto "$missing" "$full_caps"
expect_userspace 'auto without a TUN device (ARC runner container)'

run_picker auto /dev/null "$container_caps"
expect_userspace 'auto with a TUN device but without NET_ADMIN'

run_picker auto "$regular_file" "$full_caps"
expect_userspace 'auto with a TUN path that is not a character device'

run_picker auto /dev/null "$missing"
expect_userspace 'auto without a readable status file'

run_picker auto /dev/null "$no_capbnd"
expect_userspace 'auto without a CapBnd line'

run_picker auto /dev/null "$garbage_caps"
expect_userspace 'auto with a CapBnd that is not hexadecimal'

run_picker '' "$missing" "$full_caps"
expect_userspace 'empty mode behaves as auto'

# An explicit mode wins over detection.
run_picker tun "$missing" "$container_caps"
expect_tun 'tun forced without a TUN device'

run_picker userspace /dev/null "$full_caps"
expect_userspace 'userspace forced with a usable TUN device'

for bad in TUN user 'auto;id' 'tun userspace'; do
  run_picker "$bad" /dev/null "$full_caps"
  [[ "$status" == 1 ]] || fail "mode '$bad': expected exit 1, got $status"
  [[ "$(<"$out")" == *'::error title=SAST::ts_networking must be auto, tun or userspace'* ]] ||
    fail "mode '$bad': no ::error"
  [[ ! -s "$output" ]] || fail "mode '$bad': wrote outputs"
done

printf 'PASS: tailscale-networking.sh picks tun or userspace networking\n'
