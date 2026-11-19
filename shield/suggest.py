#!/usr/bin/env python3
"""Run on the shield: correlate blocked IPv4 destinations with DNS queries."""
import base64
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import ipaddress
from pathlib import Path
import re
import subprocess
import sys

QUERY = re.compile(r'query\[(?:A|AAAA)\] ([^\s]+)')
DEST = re.compile(r'\bDST=((?:[0-9]{1,3}\.){3}[0-9]{1,3})\b')
DOMAIN = re.compile(r'(?=.{1,253}$)[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+$', re.I)


def journal(*args):
    return subprocess.run(['sudo', '-n', 'journalctl', '-q', '--no-pager', '-o', 'cat', *args],
                          text=True, capture_output=True, check=True).stdout


def counts(log):
    return Counter(match.group(1).rstrip('.').lower() for match in QUERY.finditer(log))


def resolve(value, reverse=False):
    args = ['dig', '+short', '+time=2', '+tries=1', '@127.0.0.1']
    args += ['-x', value] if reverse else ['A', value]
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=3)
        if result.returncode:
            return value, [], True
        if reverse:
            return value, result.stdout.splitlines()[:1], False
        ips = []
        for line in result.stdout.splitlines():
            try:
                ips.append(str(ipaddress.IPv4Address(line)))
            except ValueError:
                pass  # CNAMEs are not addresses
        return value, list(dict.fromkeys(ips)), False
    except (OSError, subprocess.TimeoutExpired):
        return value, [], True


def main(deployment, since):
    scope = ['--since', since] if since else ['-b']
    label = f'since {since}' if since else 'this boot'
    blocked = sorted(set(DEST.findall(journal('-k', *scope))))
    if not blocked:
        print(f'nothing blocked by nftables {label} — nothing to suggest')
        return

    print(f"blocked dsts {label} ({len(blocked)}): {' '.join(blocked)}")
    window = counts(journal('-u', 'dnsmasq', *scope))
    boot = counts(journal('-u', 'dnsmasq', '-b')) if since else window
    if not boot:
        print('dnsmasq query log empty this boot (log-queries off?) — cannot name any block; use the PTR tier below')
    allowed = []
    for line in Path('/etc/dnsmasq.conf').read_text().splitlines():
        if line.startswith('nftset=/'):
            allowed.append(line.split('/')[1].lower())
    # Hostnames are never interpolated into a shell, and malformed names are
    # not actionable by shield-allow.sh, which accepts DNS names only.
    candidates = sorted(name for name in window.keys() | boot.keys()
                        if DOMAIN.fullmatch(name) and all(len(x) <= 63 for x in name.split('.'))
                        and not all(c.isdigit() or c == '.' for c in name)
                        and not any(name == domain or name.endswith('.' + domain) for domain in allowed))
    blocked_set = set(blocked)
    matches = {}
    failures = 0
    with ThreadPoolExecutor(max_workers=16) as pool:
        for name, ips, failed in pool.map(resolve, candidates):
            failures += failed
            hits = [ip for ip in ips if ip in blocked_set]
            if hits:
                matches[name] = hits
    if failures:
        print(f'Warning: {failures} DNS lookups failed; suggestions may be incomplete.', file=sys.stderr)

    final = [name for name in matches if not any(name != other and name.endswith('.' + other)
                                                for other in matches)]
    matched_ips = {ip for ips in matches.values() for ip in ips}
    if final:
        print('\nblocking these (queried names whose current IPs match blocked dsts; subsumed subdomains collapsed):')
        for name in final:
            label = f'{window[name]} queries' if window[name] else f'{boot[name]} queries before window'
            print(f"   {name:<48} {('(' + label + ')'):>28}  blocked: {','.join(matches[name])}")
        print(f"\nto allow — copy/paste:\n  ./shield-allow.sh {deployment} {' '.join(final)}")

    remaining = [ip for ip in blocked if ip not in matched_ips]
    if remaining:
        print('\nunattributed blocked IPs (no queried name resolves to them: agent cached')
        print('the answer earlier, direct-IP traffic, or RRset rotated) — owner hint:')
        with ThreadPoolExecutor(max_workers=16) as pool:
            for ip, names, _ in pool.map(lambda value: resolve(value, reverse=True), remaining):
                print(f"   {ip:<16} {names[0] if names else 'no PTR'}")
        print('allow the OWNING domain (bare IPs are garbage-collected from allow4 by')
        print('keepalive — the profile is domain-based):')
        print(f'  ./shield-allow.sh {deployment} <domain from the hint you trust>')


if __name__ == '__main__':
    try:
        main(sys.argv[1], base64.b64decode(sys.argv[2]).decode())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'shield-suggest: {exc}', file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
