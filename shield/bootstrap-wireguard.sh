#!/bin/bash
set -euo pipefail
cloud-init status --wait --long
export DEBIAN_FRONTEND=noninteractive
# GOLD images boot with unattended-upgrades running; racing it fails with the
# dpkg-frontend lock. Wait it out (cap 10 min) instead of treating it as fatal.
for _ in $(seq 1 120); do
    fuser -s /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>/dev/null || break
    sleep 5
done
apt-get update -qq
apt-get install -y wireguard dnsutils
install -d -m 700 /etc/wireguard
if [ ! -s /etc/wireguard/private.key ]; then
    umask 077
    wg genkey > /etc/wireguard/private.key
fi
wg pubkey < /etc/wireguard/private.key
