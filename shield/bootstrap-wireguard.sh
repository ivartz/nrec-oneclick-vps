#!/bin/bash
set -euo pipefail
cloud-init status --wait --long
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y wireguard dnsutils
install -d -m 700 /etc/wireguard
if [ ! -s /etc/wireguard/private.key ]; then
    umask 077
    wg genkey > /etc/wireguard/private.key
fi
wg pubkey < /etc/wireguard/private.key
