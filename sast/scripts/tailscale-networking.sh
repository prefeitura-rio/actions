#!/usr/bin/env bash
# Picks how tailscaled joins the tailnet, from TS_NETWORKING (the action's
# ts_networking input):
#   tun        kernel TUN device, the tailscale/github-action default (needs
#              /dev/net/tun and CAP_NET_ADMIN, as on GitHub-hosted runners).
#   userspace  tailscaled --tun=userspace-networking with a local SOCKS5
#              proxy, for containers without TUN (the ARC runners of the
#              organization). Only the DefectDojo uploads go through it.
#   auto       tun when the TUN device opens and CAP_NET_ADMIN is in the
#              bounding set (tailscaled runs under sudo), userspace otherwise.
# Writes mode, tailscaled_args and proxy to $GITHUB_OUTPUT. TS_TUN_DEVICE and
# TS_PROC_STATUS override /dev/net/tun and /proc/self/status (tests only).
set -euo pipefail

mode="${TS_NETWORKING:-auto}"
tun_device="${TS_TUN_DEVICE:-/dev/net/tun}"
proc_status="${TS_PROC_STATUS:-/proc/self/status}"
socks5_server="localhost:1055"
cap_net_admin=12

tun_usable() {
    [[ -c "$tun_device" ]] || return 1
    { : <>"$tun_device"; } 2>/dev/null || return 1
    local cap_bnd
    cap_bnd=$(awk '$1 == "CapBnd:" { print $2 }' "$proc_status" 2>/dev/null) || return 1
    [[ "$cap_bnd" =~ ^[0-9a-fA-F]{1,16}$ ]] || return 1
    (((16#$cap_bnd >> cap_net_admin) & 1))
}

case "$mode" in
auto)
    if tun_usable; then
        mode=tun
    else
        mode=userspace
    fi
    ;;
tun | userspace) ;;
*)
    echo "::error title=SAST::ts_networking must be auto, tun or userspace, got '$mode'"
    exit 1
    ;;
esac

tailscaled_args=""
proxy=""
if [[ "$mode" == "userspace" ]]; then
    tailscaled_args="--tun=userspace-networking --socks5-server=$socks5_server"
    # socks5h: tailscaled resolves the host name, so MagicDNS names work.
    proxy="socks5h://$socks5_server"
    echo "::notice title=Tailscale userspace networking::no usable TUN device (or ts_networking: userspace), so tailscaled runs with --tun=userspace-networking and the DefectDojo uploads go through its SOCKS5 proxy at $socks5_server"
fi

{
    echo "mode=$mode"
    echo "tailscaled_args=$tailscaled_args"
    echo "proxy=$proxy"
} >>"$GITHUB_OUTPUT"
