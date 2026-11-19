#!/bin/bash
# shield-allow.sh — add (or revoke) allowed domains on a RUNNING shield and in
# the repo profile, live: no VM redeploy, no VM restart.
# Why this is sufficient: the nft rules already test "ip daddr @allow4", so
# an nftset= line in dnsmasq.conf + a dnsmasq SERVICE restart is the entire
# apply (~2 s; kernel conntrack/nft survive, so established agent connections
# are unaffected; only name resolution is briefly down). Restart, not reload:
# dnsmasq(8) — "SIGHUP does NOT re-read the configuration file."
# Instant effect: after the restart the script resolves the domain through the
# shield's OWN dnsmasq and adds the IPs to allow4 manually (full 30-min set
# timer) — deterministic, works even if the agent's systemd-resolved still
# serves the IP from its own cache (then the agent never asks dnsmasq, which
# would otherwise never mirror it). The keepalive timer then refreshes it.
# CNAME'd domains are handled automatically: the answer's canonical domain is
# added as an extra nftset= line (dnsmasq mirrors under the canonical name).
# Revoked domains: live allow4 entries are deleted from BOTH resolver views
# and their conntrack flows flushed, so established sessions die within
# seconds; stale RRset generations no dig can rediscover are swept by the
# keepalive timer's garbage-collect (<=4 min).
# Usage: ./shield-allow.sh [--revoke] <deployment-id> <domain> [domain...]
#        SHIELD=<profile> picks a profile other than ubuntu (default).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # keys/ and shield/ are relative to THIS dir
REV=0
if [ "${1:-}" = "--revoke" ]; then REV=1; shift; fi
[ $# -ge 2 ] || { echo "usage: $0 [--revoke] <deployment-id> <domain> [domain...]"; exit 1; }
ID=$1; shift
source shield/validation.sh
for D in "$@"; do
    if ! valid_domain "$D"; then
        printf 'ERROR: invalid domain: %s (use a hostname, not a URL or IP)\n' "$D" >&2
        exit 1
    fi
done
[ -f "keys/$ID.pem" ] || { echo "ERROR: no keys/$ID.pem next to this script — run the copy in the deploy dir (on the KVM host: ~/Projects/nrec-oneclick-vps-sync)"; exit 1; }
SHIELD=${SHIELD:-ubuntu}
[[ "$SHIELD" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'ERROR: invalid profile name' >&2; exit 1; }
PROFILE="shield/profile-$SHIELD.txt"
[ -f "$PROFILE" ] || { echo "ERROR: no $PROFILE" >&2; exit 1; }
profile_domains "$PROFILE" >/dev/null
source shield/connection.sh
live_domains >/dev/null

if [ "$REV" = 1 ]; then
    for D in "$@"; do
        # Revoke both the requested name and its CNAME, then clear addresses
        # from both DNS views and their established conntrack flows.
        CANONR=$($SSH "dig +short A $D" | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 | sed 's/\.$//') || true
        if [ -n "$CANONR" ] && ! valid_domain "$CANONR"; then
            printf 'ERROR: invalid CNAME target: %s\n' "$CANONR" >&2
            exit 1
        fi
        if [ -n "$CANONR" ] && [ "$CANONR" != "$D" ]; then
            sed -i "\#^$CANONR\$#d" "$PROFILE"
        else
            CANONR=
        fi
        sed -i "\#^$D\$#d" "$PROFILE"
        $SSH "for ip in \$( (dig +short A $D @127.0.0.1; dig +short A $D; dig +short A ${CANONR:-$D} @127.0.0.1; dig +short A ${CANONR:-$D}) | grep -E '^[0-9.]+\$' | sort -u); do sudo nft delete element inet shield allow4 { \$ip } 2>/dev/null || true; sudo conntrack -D -r \$ip >/dev/null 2>&1 || true; done; sudo sed -i -e '\\#nftset=/$D/#d' -e '\\#nftset=/${CANONR:-none}/#d' /etc/dnsmasq.conf"
    done
    $SSH "sudo systemctl restart dnsmasq"
    echo "revoked: $* — no longer live on $GW, removed from $PROFILE"
else
    # Resolve CNAMEs in one SSH session. All requested and returned names are
    # validated before embedding them in a remote command or dnsmasq rule.
    PAIRS=$($SSH "for d in $*; do
        c=\$(dig +short A \"\$d\" | grep -vE '^([0-9]{1,3}\\.){3}[0-9]{1,3}\$' | head -1 | sed 's/\\.\$//')
        printf '%s|%s\\n' \"\$d\" \"\$c\"
    done")
    CANONS=""
    while IFS='|' read -r D CANON; do
        [ -n "$D" ] || continue
        if [ -n "$CANON" ] && ! valid_domain "$CANON"; then
            printf 'ERROR: invalid CNAME target: %s\n' "$CANON" >&2
            exit 1
        fi
        if [ -n "$CANON" ] && [ "$CANON" != "$D" ]; then
            echo "CNAME target detected: $CANON — auto-adding it too"
            CANONS="$CANONS $CANON"
        fi
    done <<< "$PAIRS"
    for D in "$@" $CANONS; do
        grep -qxF "$D" "$PROFILE" || echo "$D" >> "$PROFILE"
    done
    # Append validated rules, restart dnsmasq, and prime every current IPv4 in
    # one SSH session. Keepalive refreshes the set until the domain is revoked.
    $SSH "set -e
    for d in $* $CANONS; do
        rule=\"nftset=/\$d/4#inet#shield#allow4\"
        grep -qxF \"\$rule\" /etc/dnsmasq.conf || printf '%s\\n' \"\$rule\" | sudo tee -a /etc/dnsmasq.conf >/dev/null
    done
    sudo systemctl restart dnsmasq
    for d in $* $CANONS; do
        ips=\$(dig +short A \"\$d\" @127.0.0.1 | grep -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}\$' || true)
        if [ -z \"\$ips\" ]; then
            printf '  WARN: %s resolved to no IPv4 (IPv6-only or missing apex A record?)\\n' \"\$d\"
            continue
        fi
        for ip in \$ips; do
            sudo nft delete element inet shield allow4 \"{ \$ip }\" 2>/dev/null || true
            sudo nft add element inet shield allow4 \"{ \$ip }\"
            printf '  %s -> %s in allow4\\n' \"\$d\" \"\$ip\"
        done
    done"
    echo "allowed: $* — live on $GW + recorded in $PROFILE"
fi
