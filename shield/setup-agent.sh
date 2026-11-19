#!/bin/bash
# sudo setup-agent.sh SHIELD_IPV4 SHIELD_PUBLIC_KEY
# Ubuntu agent: all IPv4 defaults through wg0; external Neutron SGs are the
# security boundary (sudo inside the agent can undo local routing).
# Parent generates /etc/wireguard/private.key; never generate keys here.
set -euo pipefail
umask 077
if [ "$#" -ne 2 ] || [ "$EUID" -ne 0 ]; then
    printf 'usage: sudo %s SHIELD_IPV4 SHIELD_PUBLIC_KEY\n' "$0" >&2
    exit 2
fi
shield_ipv4=$1
shield_public_key=$2
for command in python3 ip wg wg-quick systemctl resolvectl; do
    command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done
[ -s /etc/wireguard/private.key ] || { printf 'Missing /etc/wireguard/private.key\n' >&2; exit 1; }
# Validate values before interpolation; private key is read only from the file,
# never argv, and no command tracing is enabled.
python3 - "$shield_ipv4" "$shield_public_key" <<'PY'
import base64
import ipaddress
from pathlib import Path
import re
import sys
ipaddress.IPv4Address(sys.argv[1])
for name, value in [('shield public key', sys.argv[2]),
                    ('agent private key', Path('/etc/wireguard/private.key').read_text().strip())]:
    if not re.fullmatch(r'[A-Za-z0-9+/]{43}=', value) or len(base64.b64decode(value, validate=True)) != 32:
        raise SystemExit(f'Invalid {name}')
PY
# On reapply remove the previous wg-quick policy routing before discovering
# the real WAN source. Leave a fresh interface stopped until config is ready.
if systemctl is-active --quiet wg-quick@wg0.service; then
    systemctl stop wg-quick@wg0.service
elif ip link show wg0 >/dev/null 2>&1; then
    printf 'wg0 exists but is not managed by wg-quick@wg0; refusing to replace it\n' >&2
    exit 1
fi
route=$(ip -j -4 route get "$shield_ipv4")
read -r wan underlay_ipv4 < <(python3 - "$route" <<'PY'
import ipaddress
import json
import re
import sys
route = json.loads(sys.argv[1])[0]
dev = route['dev']
if not re.fullmatch(r'[A-Za-z0-9_.:-]+', dev) or dev in ('wg0', 'lo'):
    raise SystemExit('No usable WAN route to shield')
print(dev, ipaddress.IPv4Address(route.get('prefsrc') or route['src']))
PY
)
# Reserve a priority ahead of wg-quick's 32764/32765 policy. Source routing
# keeps SSH replies from the underlay address direct to the operator, even
# when wg0 is the full-tunnel default. Neutron must restrict underlay egress.
# Refuse to overwrite an unrelated policy at this reserved priority.
if ip -4 rule show | grep -q '^10000:'; then
    printf 'IP rule priority 10000 is already in use; refusing to overwrite it\n' >&2
    exit 1
fi
install -d -m 700 /etc/wireguard
chmod 600 /etc/wireguard/private.key
private_key=$(tr -d '\r\n' < /etc/wireguard/private.key)
config=$(mktemp /etc/wireguard/.wg0.XXXXXX)
trap 'rm -f "$config"' EXIT
# wg-quick's fwmark bypass automatically preserves the outer UDP endpoint.
# DNS is applied by resolvectl, not wg-quick's DNS= (which requires resolvconf).
printf '%s\n' \
    '[Interface]' \
    'Address = 10.99.0.10/24' \
    "PrivateKey = $private_key" \
    'ListenPort = 51820' \
    'PostUp = sysctl -q -w net.ipv4.conf.%i.rp_filter=2' \
    'PostUp = resolvectl dns %i 10.99.0.2' \
    'PostUp = resolvectl domain %i ~.' \
    'PostUp = resolvectl default-route %i yes' \
    "PostUp = ip -4 rule add priority 10000 from $underlay_ipv4/32 lookup main" \
    "PostDown = ip -4 rule del priority 10000 from $underlay_ipv4/32 lookup main || true" \
    'PostDown = resolvectl revert %i || true' \
    '' \
    '[Peer]' \
    "PublicKey = $shield_public_key" \
    "Endpoint = $shield_ipv4:51820" \
    'AllowedIPs = 0.0.0.0/0' \
    'PersistentKeepalive = 25' > "$config"
unset private_key
# Validate without displaying the stripped config (contains the private key).
# wg-quick accepts a path only when its basename ends in .conf.
validation_dir=$(mktemp -d /etc/wireguard/.validate.XXXXXX)
trap 'rm -f "$config"; rm -rf "$validation_dir"' EXIT
cp "$config" "$validation_dir/wg0.conf"
wg-quick strip "$validation_dir/wg0.conf" >/dev/null
mv "$config" /etc/wireguard/wg0.conf
rm -rf "$validation_dir"
trap - EXIT
# Loose reverse-path filtering preserves SSH under asymmetric default routing.
install -d -m 755 /etc/sysctl.d
printf '%s\n' \
    'net.ipv4.conf.all.rp_filter = 2' \
    'net.ipv4.conf.default.rp_filter = 2' \
    "net.ipv4.conf.$wan.rp_filter = 2" \
    > /etc/sysctl.d/99-agent-wireguard.conf
sysctl -q -p /etc/sysctl.d/99-agent-wireguard.conf
install -d -m 755 /etc/systemd/system/wg-quick@wg0.service.d
printf '%s\n' \
    '[Unit]' \
    'Requires=systemd-resolved.service' \
    'After=systemd-resolved.service network-online.target' \
    > /etc/systemd/system/wg-quick@wg0.service.d/resolved.conf
systemctl daemon-reload
systemctl enable --now systemd-resolved.service
# Applications must query resolved's stub, not an old DHCP resolv.conf.
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable --now wg-quick@wg0.service
systemctl is-active --quiet wg-quick@wg0.service
systemctl is-active --quiet systemd-resolved.service
[ "$(wg show wg0 allowed-ips)" = "$(printf '%s\t0.0.0.0/0' "$shield_public_key")" ]
ip -4 rule show | grep -F "from $underlay_ipv4 lookup main" >/dev/null
ip -j -4 route get 1.1.1.1 | python3 -c \
    'import json,sys; route=json.load(sys.stdin)[0]; assert route["dev"] == "wg0", route'
resolvectl dns wg0 | grep -F '10.99.0.2' >/dev/null
resolvectl domain wg0 | grep -F '~.' >/dev/null
printf 'Agent configured: wg0=10.99.0.10; IPv4 default through %s:51820; SSH replies from %s stay on %s.\n' \
    "$shield_ipv4" "$underlay_ipv4" "$wan"
printf 'Local service/routing/DNS configuration checked; handshake and allowed/denied egress need remote verification.\n'
