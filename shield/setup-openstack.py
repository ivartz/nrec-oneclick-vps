#!/usr/bin/env python3
"""sudo setup-openstack.py CONFIG_JSON PROFILE_FILE

Standalone Ubuntu shield installer; no Terraform keys, netplan or NIC renaming.
Owns /etc/nftables.conf and /etc/dnsmasq.conf on a dedicated shield VM.
IPv4-only tunnel; Neutron must deny agent underlay egress except WG/operator
SSH replies, and deny IPv6. The agent has sudo, so routing alone is NOT isolation.
Monitor/keepalive payloads below are copied from cloud-init-shield.yaml.tftpl.
"""
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# Populated from the KVM template at development time, not needed remotely.
KVM_FILES = {
    '/usr/local/lib/shield/monitor.sh': (r"""#!/bin/bash
# shield-report: one-screen audit of the agent VM's network behavior.
# Usage: shield-report [since-duration]  (default: last 1 hour)
# Runs automatically via shield-monitor.timer (every 10 min) -> journalctl -u shield-monitor
SINCE="${1:-1 hour}"
echo "===== shield report $(date -Is) (since: $SINCE) ====="
echo "-- nft forward rules (with counters) --"
nft -a list chain inet shield forward 2>/dev/null | grep counter
echo "-- live allow4 entries (resolved IPs behind allowed domains) --"
nft -a list set inet shield allow4 2>/dev/null | grep -v '^\s*}' | tail -25
echo "-- denies seen from agent (kernel log) --"
journalctl -k --since "$SINCE ago" -q 2>/dev/null | grep -F '[shield-drop]' | tail -20
echo "-- agent DNS queries, top 15 --"
journalctl -u dnsmasq --since "$SINCE ago" -q 2>/dev/null \
  | grep -oE 'query\[[A-Z]+\] [^ ]+' | awk '{print $2}' | sort | uniq -c | sort -rn | head -15
echo "-- live connections through the shield (conntrack) --"
conntrack -L 2>/dev/null | grep -oE 'dst=[0-9.]+' | sort | uniq -c | sort -rn | head -10
""", 0o755),
    '/usr/local/lib/shield/keepalive.sh': (r"""#!/bin/bash
# keepalive.sh — refresh allow4 membership for every profile domain.
# Why needed: dnsmasq mirrors a domain's IPs into allow4 only when it
# receives an UPSTREAM reply; long-TTL records (e.g. 48-min TTL) are not
# re-fetched before the set's 30-min element timeout, so allowlisted
# access silently lapses. Re-resolve (dnsmasq answers from its own cache,
# no upstream traffic) and reset each element's timer with separate
# nft delete + nft add calls. The timer fires every 4 min, far below the
# 30-min expiry: no gap.
set -u
# Build the wanted set: every IP that a still-profiled domain CURRENTLY
# answers with (dnsmasq's own view = what agents actually receive).
WANT=()
for d in $(grep -oP '(?<=nftset=/)[^/]+(?=/4#inet#shield#allow4)' /etc/dnsmasq.conf); do
    for ip in $(dig +short A "$d" @127.0.0.1 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'); do
        WANT+=("$ip")
    done
done
for ip in "${WANT[@]}"; do
    # NOTE: two separate nft calls. Putting both statements (plus
    # "2>/dev/null") inside ONE quoted nft string makes nft itself
    # parse the redirect -> syntax error -> silent no-op.
    nft delete element inet shield allow4 "{ $ip }" 2>/dev/null || true
    nft add element inet shield allow4 "{ $ip }" 2>/dev/null || true
done
# Garbage-collect stale generations: round-robin/CDN domains rotate
# their RRset, and a revoked domain's cached IPs can't be re-discovered
# by digging it (its line is gone from dnsmasq.conf). Anything in the
# set that no profile domain currently answers gets deleted here —
# otherwise such entries sit out their 30-min timer and keep a revoked
# site reachable (observed: nevron.no CDN IPs survived its revoke).
for ip in $(nft list set inet shield allow4 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u); do
    case " ${WANT[*]} " in
        *" $ip "*) continue ;;
    esac
    nft delete element inet shield allow4 "{ $ip }" 2>/dev/null || true
    conntrack -D -r "$ip" >/dev/null 2>&1 || true
done
""", 0o755),
    '/etc/systemd/system/shield-keepalive.service': (r"""[Unit]
Description=Refresh allow4 entries for shield profile domains
[Service]
Type=oneshot
ExecStart=/usr/local/lib/shield/keepalive.sh
""", 0o644),
    '/etc/systemd/system/shield-keepalive.timer': (r"""[Unit]
Description=Refresh allow4 every 4 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=4min
AccuracySec=30s
[Install]
WantedBy=timers.target
""", 0o644),
    '/usr/local/bin/shield-report': (r"""#!/bin/bash
exec /usr/local/lib/shield/monitor.sh "$@"
""", 0o755),
    '/etc/systemd/system/shield-monitor.service': (r"""[Unit]
Description=Shield network audit snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/lib/shield/monitor.sh
""", 0o644),
    '/etc/systemd/system/shield-monitor.timer': (r"""[Unit]
Description=shield-report every 10 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
""", 0o644),
}


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def key(value, name):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9+/]{43}=', value):
        raise ValueError(f'{name}: expected a WireGuard base64 key')
    if len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError(f'{name}: expected a 32-byte WireGuard key')
    return value


def load_inputs(config_file, profile_file):
    config = json.loads(Path(config_file).read_text())
    for name in ('shield_private_key', 'agent_public_key'):
        config[name] = key(config[name], name)
    for name in ('agent_ipv4', 'operator_ipv4'):
        config[name] = str(ipaddress.IPv4Address(config[name]))
    domains = []
    for line in Path(profile_file).read_text().splitlines():
        domain = line.split('#', 1)[0].strip().lower()
        if not domain:
            continue
        if len(domain) > 253 or not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label)
                                      for label in domain.split('.')):
            raise ValueError(f'invalid profile domain: {domain!r}')
        if domain not in domains:
            domains.append(domain)
    # Empty profile is intentionally supported (deny all).
    return config, domains


def render(config, domains, wan):
    if not re.fullmatch(r'[a-zA-Z0-9_.:-]+', wan) or wan in ('wg0', 'lo'):
        raise ValueError('invalid WAN interface')
    nft = f'''flush ruleset

table inet shield {{
    set allow4 {{
        type ipv4_addr
        flags dynamic,timeout
        timeout 30m
    }}
    chain forward {{
        type filter hook forward priority 0; policy drop;
        ct state invalid drop
        iifname "wg0" oifname "{wan}" ip saddr 10.99.0.10 ct state established,related accept
        iifname "{wan}" oifname "wg0" ip daddr 10.99.0.10 ct state established,related accept
        iifname "wg0" oifname "{wan}" ip saddr 10.99.0.10 ip daddr @allow4 tcp dport {{ 80, 443 }} counter accept
        iifname "wg0" oifname "{wan}" ip saddr 10.99.0.10 ip daddr @allow4 udp dport 443 counter accept
        iifname "wg0" oifname "{wan}" ip saddr 10.99.0.10 ip daddr @allow4 udp dport 123 counter accept
        iifname "wg0" limit rate 60/minute burst 20 packets counter log prefix "[shield-drop] "
        iifname "wg0" counter reject with icmpx type port-unreachable
    }}
    chain input {{
        type filter hook input priority 0; policy accept;
        ct state invalid drop
        iifname "wg0" ip saddr 10.99.0.10 udp dport 53 counter accept
        iifname "wg0" ip saddr 10.99.0.10 tcp dport 53 counter accept
        iifname "wg0" ip saddr 10.99.0.10 icmp type {{ echo-request, destination-unreachable, time-exceeded, parameter-problem }} counter accept
        # No agent-to-shield SSH (including already-established connections).
        iifname "wg0" counter reject with icmpx type port-unreachable
        # WAN ingress remains the responsibility of the OpenStack security group.
    }}
    chain postrouting {{
        type nat hook postrouting priority 100;
        oifname "{wan}" ip saddr 10.99.0.10 masquerade
    }}
}}
'''
    dns = '''interface=wg0
interface=lo
listen-address=10.99.0.2,127.0.0.1
bind-interfaces
port=53
domain-needed
bogus-priv
localise-queries
log-queries
no-poll
no-resolv
min-cache-ttl=1800
server=8.8.8.8
server=1.1.1.1
'''
    dns += ''.join(f'nftset=/{domain}/4#inet#shield#allow4\n' for domain in domains)
    wg = f'''[Interface]
Address = 10.99.0.2/24
ListenPort = 51820
PrivateKey = {config['shield_private_key']}

[Peer]
PublicKey = {config['agent_public_key']}
AllowedIPs = 10.99.0.10/32
'''
    files = dict(KVM_FILES)
    files.update({
        '/etc/nftables.conf': (nft, 0o644),
        '/etc/dnsmasq.conf': (dns, 0o644),
        '/etc/wireguard/wg0.conf': (wg, 0o600),
        '/etc/sysctl.d/99-shield-forward.conf':
            ('net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 0\n', 0o644),
        '/etc/systemd/system/wg-quick@wg0.service.d/shield.conf':
            ('[Unit]\nRequires=nftables.service\nAfter=nftables.service\n', 0o644),
        '/etc/systemd/system/dnsmasq.service.d/shield.conf':
            ('[Unit]\nRequires=wg-quick@wg0.service nftables.service\n'
             'After=wg-quick@wg0.service nftables.service\n'
             '[Service]\nExecStartPost=/usr/local/lib/shield/keepalive.sh\n', 0o644),
        '/etc/systemd/system/shield-keepalive.service.d/network.conf':
            ('[Unit]\nRequires=dnsmasq.service\nAfter=dnsmasq.service\n', 0o644),
        '/etc/systemd/system/shield-monitor.service.d/network.conf':
            ('[Unit]\nAfter=dnsmasq.service nftables.service\n', 0o644),
    })
    return files


def install(path, text, mode):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.' + target.name, dir=target.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as handle:
            handle.write(text)
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    if len(sys.argv) != 3:
        raise ValueError('usage: sudo setup-openstack.py CONFIG_JSON PROFILE_FILE')
    config, domains = load_inputs(*sys.argv[1:])
    if os.geteuid() != 0:
        raise ValueError('run with sudo on the shield VM')
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
    devices = {route['dev'] for route in routes if route.get('dev') != 'wg0'}
    if len(devices) != 1:
        raise ValueError('expected one WAN interface with an IPv4 default route')
    wan = devices.pop()
    files = render(config, domains, wan)
    # Validate generated syntax before replacing any live configuration.
    with tempfile.TemporaryDirectory(prefix='shield-setup-') as directory:
        root = Path(directory)
        for name, (text, mode) in files.items():
            staged = root / name.lstrip('/')
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(text)
            staged.chmod(mode)
            if name.endswith('.sh') or name == '/usr/local/bin/shield-report':
                run('bash', '-n', str(staged))
        run('nft', '-c', '-f', str(root / 'etc/nftables.conf'))
        run('dnsmasq', '--test', '--conf-file=' + str(root / 'etc/dnsmasq.conf'))
        # wg-quick strip does not need or create a live interface.
        run('wg-quick', 'strip', str(root / 'etc/wireguard/wg0.conf'))
    for name, (text, mode) in files.items():
        install(name, text, mode)
    Path('/var/log/shield').mkdir(parents=True, exist_ok=True)
    Path('/etc/wireguard').chmod(0o700)
    run('systemctl', 'daemon-reload')
    # Stop old DNS/timers before replacing the ruleset and tunnel on reapply.
    run('systemctl', 'stop', 'shield-keepalive.timer', 'shield-monitor.timer')
    run('systemctl', 'stop', 'shield-keepalive.service', 'shield-monitor.service',
        'dnsmasq.service', 'wg-quick@wg0.service')
    # The tunnel is now down: nftables ExecStop may flush the old ruleset,
    # so never restart this service while a live agent can forward traffic.
    run('systemctl', 'enable', 'nftables.service', 'wg-quick@wg0.service', 'dnsmasq.service')
    run('systemctl', 'restart', 'nftables.service')
    run('sysctl', '-q', '-p', '/etc/sysctl.d/99-shield-forward.conf')
    run('systemctl', 'restart', 'wg-quick@wg0.service')
    run('systemctl', 'restart', 'dnsmasq.service')
    run('systemctl', 'enable', '--now', 'shield-keepalive.timer', 'shield-monitor.timer')
    # is-active with multiple units succeeds if ANY is active; check each.
    for unit in ('nftables.service', 'wg-quick@wg0.service', 'dnsmasq.service',
                 'shield-keepalive.timer', 'shield-monitor.timer'):
        run('systemctl', 'is-active', '--quiet', unit)
    run('nft', 'list', 'table', 'inet', 'shield')
    if run('wg', 'show', 'wg0', 'allowed-ips').strip() != config['agent_public_key'] + '\t10.99.0.10/32':
        raise ValueError('live WireGuard peer does not match configuration')
    answer = run('dig', '@127.0.0.1', 'localhost', '+time=2', '+tries=1')
    if 'status:' not in answer:
        raise ValueError('dnsmasq did not answer on loopback')
    print(f'Shield configured on {wan}: wg0=10.99.0.2, {len(domains)} profile domains. '
          f'Agent underlay {config["agent_ipv4"]}; operator {config["operator_ipv4"]}. '
          'Services/peer/local DNS checked; remote handshake/egress still require agent verification.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as exc:
        # Never print subprocess stdout: wg-quick strip contains the private key.
        print(f'ERROR: {exc.cmd[0]} failed (exit {exc.returncode}): {exc.stderr.strip()}', file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, OSError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
