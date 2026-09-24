#!/usr/bin/env bash
# Brings up Tailscale inside a GitLab CI job so the scanners can reach the
# internal DefectDojo / SonarQube hosts on the tailnet. GitHub used the
# tailscale/github-action; here we drive the CLI directly.
#
# Required env (set as masked CI/CD variables):
#   TS_OAUTH_SECRET  - Tailscale OAuth client secret (used directly as the auth key)
#   TS_TAGS          - comma-separated ACL tags the node advertises (e.g. tag:ci)
# Optional:
#   TS_OAUTH_CLIENT_ID - accepted for parity with the GitHub action; the CLI only
#                        needs the secret + tags, so it is not otherwise used.
#   TS_VERSION         - tailscale release to install (default below)
#
# Runner note: TUN mode needs /dev/net/tun (privileged runner or a device mount).
# Without it we fall back to userspace networking and export ALL_PROXY/HTTPS_PROXY;
# for the fallback to reach the tailnet from the rest of the job, source this file
# (". tailscale-up.sh") instead of running it, or set those proxies as CI variables.
set -eo pipefail

if [ -z "${TS_OAUTH_SECRET:-}" ]; then
  echo "tailscale-up: TS_OAUTH_SECRET not set; skipping Tailscale (assuming the runner already has network access to the internal hosts)."
  return 0 2>/dev/null || exit 0
fi
: "${TS_TAGS:?TS_TAGS is required when TS_OAUTH_SECRET is set}"

TS_VERSION="${TS_VERSION:-1.80.2}"

if ! command -v tailscaled >/dev/null 2>&1; then
  echo "tailscale-up: installing tailscale ${TS_VERSION}..."
  tmp="$(mktemp -d)"
  curl -sfL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_amd64.tgz" -o "$tmp/ts.tgz"
  tar -xzf "$tmp/ts.tgz" -C "$tmp" --strip-components=1
  install -m 0755 "$tmp/tailscaled" /usr/local/bin/tailscaled
  install -m 0755 "$tmp/tailscale" /usr/local/bin/tailscale
  rm -rf "$tmp"
fi

mkdir -p /var/run/tailscale /var/lib/tailscale
SOCK=/var/run/tailscale/tailscaled.sock

if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "tailscale-up: tailscaled already running."
else
  if [ -c /dev/net/tun ]; then
    echo "tailscale-up: starting tailscaled (TUN mode)."
    tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$SOCK" \
      >/tmp/tailscaled.log 2>&1 &
  else
    echo "tailscale-up: /dev/net/tun missing; starting tailscaled (userspace networking)."
    tailscaled --tun=userspace-networking --socks5-server=localhost:1055 \
      --outbound-http-proxy-listen=localhost:1055 \
      --state=/var/lib/tailscale/tailscaled.state --socket="$SOCK" \
      >/tmp/tailscaled.log 2>&1 &
    export ALL_PROXY="socks5h://localhost:1055/"
    export HTTPS_PROXY="http://localhost:1055/"
    export HTTP_PROXY="http://localhost:1055/"
    # Keep local traffic and the GitLab coordinator off the tailnet proxy.
    export NO_PROXY="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,${CI_SERVER_HOST:-localhost}"
    export no_proxy="$NO_PROXY"
  fi
fi

for _ in $(seq 1 30); do
  [ -S "$SOCK" ] && break
  sleep 1
done

tailscale --socket="$SOCK" up \
  --authkey="${TS_OAUTH_SECRET}" \
  --advertise-tags="${TS_TAGS}" \
  --hostname="gitlab-sast-${CI_PROJECT_ID:-x}-${CI_JOB_ID:-x}" \
  --accept-routes

tailscale --socket="$SOCK" status || true
