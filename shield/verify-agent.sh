#!/bin/bash
# Run as root on agent after SG lockdown; tests actual paths, not config alone.
set -euo pipefail
[ "$EUID" = 0 ] || exit 2
pass() { printf 'PASS: %s\n' "$*"; }
blocked() {
    local expected=$1; shift
    local rc=0
    "$@" || rc=$?
    [ "$rc" = "$expected" ] || { echo "FAIL: expected exit $expected, got $rc: $*"; exit 1; }
}
curl -4 -fsSI --max-time 20 https://archive.ubuntu.com
pass 'allowlisted HTTPS through shield'
blocked 7 curl -4 -fsSI --max-time 10 https://example.com
pass 'unlisted HTTPS rejected'
python3 - <<'PY'
import socket
s=socket.socket();s.settimeout(3)
try:
    s.connect(('10.99.0.2',22))
except OSError:
    print('PASS: agent cannot SSH to shield over tunnel')
else:
    raise SystemExit('FAIL: shield SSH reachable')
finally:s.close()
PY
WAN=$(ip -j -4 route show default | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["dev"])')
IP=$(dig +short A archive.ubuntu.com @10.99.0.2 | grep -E '^[0-9.]+$' | sed -n '1p')
[ -n "$IP" ] || { echo 'FAIL: no allowed test address'; exit 1; }
blocked 28 curl -4 -fsSI --max-time 5 --interface "$WAN" --resolve "archive.ubuntu.com:443:$IP" https://archive.ubuntu.com
pass 'forced IPv4 underlay bypass blocked by Neutron'
blocked 28 curl -6 -fsSI --max-time 5 --resolve 'cloudflare-dns.com:443:[2606:4700:4700::1111]' https://cloudflare-dns.com
pass 'direct IPv6 bypass blocked by Neutron'
DNS=$(dig @1.1.1.1 example.com +time=2 +tries=1 2>&1 || true)
printf '%s\n' "$DNS"
[[ "$DNS" != *'status: NOERROR'* ]] || { echo 'FAIL: external DNS reachable'; exit 1; }
pass 'external DNS bypass blocked'
# Agent sudo can remove routing, but cannot remove the external SG boundary.
trap 'systemctl start wg-quick@wg0' EXIT
systemctl stop wg-quick@wg0
blocked 28 curl -4 -fsSI --max-time 5 --resolve "archive.ubuntu.com:443:$IP" https://archive.ubuntu.com
pass 'disabling WireGuard does not restore internet'
systemctl start wg-quick@wg0
trap - EXIT
curl -4 -fsSI --retry 3 --retry-all-errors --max-time 20 https://archive.ubuntu.com
pass 'tunnel/service restart restores permitted access'
wg show wg0 latest-handshakes | awk '{if ($2 == 0) exit 1}'
pass 'WireGuard handshake present'
