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
#        SHIELD=<profile> picks a profile other than sandbox (default).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # keys/ and shield/ are relative to THIS dir
REV=0
if [ "${1:-}" = "--revoke" ]; then REV=1; shift; fi
[ $# -ge 2 ] || { echo "usage: $0 [--revoke] <deployment-id> <domain> [domain...]"; exit 1; }
ID=$1; shift
[ -f "keys/$ID.pem" ] || { echo "ERROR: no keys/$ID.pem next to this script — run the copy in the deploy dir (on the KVM host: ~/Projects/nrec-oneclick-vps-sync)"; exit 1; }
SHIELD=${SHIELD:-sandbox}
HEX=${ID#vps-local-}
GW="10.99.$(( 16#${HEX: -2} % 239 + 1 )).2"   # same subnet derivation as deploy-local.sh
# LogLevel=ERROR silences the "Warning: Permanently added ..." noise that
# UserKnownHostsFile=/dev/null prints on every connection (we discard known
# hosts on purpose: agentbox IPs are reused with fresh keys per redeploy).
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i keys/$ID.pem ubuntu@$GW"
PROFILE="shield/profile-$SHIELD.txt"

for D in "$@"; do
    if [ "$REV" = 1 ]; then
        # CNAME symmetry (mirror of the add path): the canonical target got
        # its own nftset= line + profile entry when allowed; revoke removes
        # both too, else the domain's IPs keep mirroring under the canonical
        # name and the revoke silently does nothing.
        CANONR=$($SSH "dig +short A $D" | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 | sed 's/\.$//') || true
        if [ -n "$CANONR" ] && [ "$CANONR" != "$D" ]; then
            [ -f "$PROFILE" ] && sed -i "\#^$CANONR\$#d" "$PROFILE" || true
            CANONR=${CANONR:-no-such-line}
        else
            CANONR=
        fi
        [ -f "$PROFILE" ] && sed -i "\#^$D\$#d" "$PROFILE" || true
        # Delete live set entries for EVERY IP the domain may have handed
        # out, from BOTH resolver views: dnsmasq's cache (@127.0.0.1 — what
        # agents actually get) and live upstream. Round-robin/CDN domains
        # rotate their RRset, so digging one view alone leaves other IPs
        # alive in allow4 (observed: nevron CDN IP stayed reachable).
        # Also flush conntrack: the forward chain accepts ct-established
        # traffic regardless of allow4, so an open browser tab would keep
        # streaming until closed; deleting the flows makes revoke instant.
        $SSH "for ip in \$( (dig +short A $D @127.0.0.1; dig +short A $D; dig +short A ${CANONR:-$D} @127.0.0.1; dig +short A ${CANONR:-$D}) | grep -E '^[0-9.]+\$' | sort -u); do sudo nft delete element inet shield allow4 { \$ip } 2>/dev/null || true; sudo conntrack -D -r \$ip >/dev/null 2>&1 || true; done; sudo sed -i -e '\\#nftset=/$D/#d' -e '\\#nftset=/${CANONR:-none}/#d' /etc/dnsmasq.conf"
    else
        { [ -f "$PROFILE" ] && grep -qxF "$D" "$PROFILE"; } || echo "$D" >> "$PROFILE"
        $SSH "grep -qF 'nftset=/$D/' /etc/dnsmasq.conf || echo 'nftset=/$D/4#inet#shield#allow4' | sudo tee -a /etc/dnsmasq.conf >/dev/null"
    fi
done

# CNAME trap (add path): dnsmasq mirrors under the answer's CANONICAL name;
# detect it from the A answer and add that domain as an extra nftset= line.
CANONS=""
if [ "$REV" = 0 ]; then
    for D in "$@"; do
        CANON=$($SSH "dig +short A $D" | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 | sed 's/\.$//') || true
        if [ -n "$CANON" ] && [ "$CANON" != "$D" ]; then
            echo "CNAME target detected: $CANON — auto-adding it too"
            { [ -f "$PROFILE" ] && grep -qxF "$CANON" "$PROFILE"; } || echo "$CANON" >> "$PROFILE"
            $SSH "grep -qF 'nftset=/$CANON/' /etc/dnsmasq.conf || echo 'nftset=/$CANON/4#inet#shield#allow4' | sudo tee -a /etc/dnsmasq.conf >/dev/null"
            CANONS="$CANONS $CANON"
        fi
    done
fi

$SSH "sudo systemctl restart dnsmasq"

if [ "$REV" = 1 ]; then
    echo "revoked: $* — no longer live on $GW, removed from $PROFILE"
else
    # prime allow4 deterministically: manual add runs on the kernel clock and
    # gets the set's full 30-min timeout (dnsmasq's own mirror only fires on
    # upstream refetches — long-TTL domains would otherwise lapse; the
    # shield-keepalive.timer on the VM refreshes every profile domain every
    # 4 min, so primed entries never expire while still in the profile).
    # Prime EVERY current IP (multi-A/round-robin domains: priming only the
    # first leaves the others unprimed until the next keepalive tick).
    for D in "$@" $CANONS; do
        [ -n "$D" ] || continue
        IPS=$($SSH "dig +short A $D @127.0.0.1" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$IPS" ]; then
            for IP in $IPS; do
                # two separate nft calls: one quoted string with an embedded
                # "2>/dev/null" makes nft choke (syntax error, silent no-op)
                $SSH "sudo nft delete element inet shield allow4 \"{ $IP }\" 2>/dev/null; sudo nft add element inet shield allow4 \"{ $IP }\""
                echo "  $D -> $IP in allow4"
            done
        else
            echo "  WARN: $D resolved to no IPv4 (IPv6-only or missing apex A record?)"
        fi
    done
    echo "allowed: $* — live on $GW + recorded in $PROFILE"
fi
