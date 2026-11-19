#!/bin/bash
# shield-suggest.sh — each manual run reports ALL traffic nftables has blocked
# and suggests how to allow it. Correlates three live sources on the shield VM:
#   1. kernel log [shield-drop] lines (the blocked dst IPs)
#   2. dnsmasq query log (names the agent's browser really asked for)
#   3. the live nftset= allow list (incl. shield-allow.sh additions)
# Every blocked dst ends up actionable:
#   - a queried, not-yet-allowed name whose current IPs (resolved through the
#     shield's own dnsmasq = the answer the agent got) match blocked dsts ->
#     listed with its blocked IPs and included in one copy/paste
#     shield-allow.sh command (subsumed subdomains collapsed: dnsmasq
#     /domain/ covers subdomains). Names queried only OUTSIDE the --since
#     window still qualify (labelled "before window") — a page often resolves
#     earlier and its connections get denied later.
#   - a blocked IP no queried name currently resolves to (agent cached the
#     answer long ago, direct-IP traffic, or the RRset rotated) -> listed with
#     a reverse-DNS (PTR) hint naming the owner, so you can allow that domain.
#     Bare IPs are NOT allowable by design: allow4 is fed by domain profiles
#     and keepalive garbage-collects any element no profile domain answers
#     with — allow the owning domain instead.
# Re-run after allowing: allowed names drop out. Nothing is allowed
# automatically; the human picks.
# Usage: ./shield-suggest.sh <deployment-id> [--since <spec>]
#   --since  like journalctl: "5 min ago", "10:00", "today", ... — window the
#            DENY log is read from (query log is always this boot: resolutions
#            legitimately happen before the denied connections).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # keys/ is relative to THIS dir
ID=${1:?usage: shield-suggest.sh <deployment-id> [--since <spec>]}
SINCE=""
if [ "${2:-}" = "--since" ]; then
    SINCE=${3:?--since needs a spec, e.g. "5 min ago"}
fi
[ -f "keys/$ID.pem" ] || { echo "ERROR: no keys/$ID.pem — run from the deploy dir"; exit 1; }
source shield/connection.sh

# window: --since spec passed straight to journalctl, else current boot
if [ -n "$SINCE" ]; then
    SCOPE="--since \"$SINCE\""
    SCOPE_LABEL="since $SINCE"
else
    SCOPE="-b"
    SCOPE_LABEL="this boot"
fi

BLOCKED=$($SSH "sudo journalctl -k $SCOPE -q | grep -F '[shield-drop]' \
    | grep -oE ' DST=[0-9]{1,3}(\.[0-9]{1,3}){3}' | cut -d= -f2 | sort -u")
QUERIED_WIN=$($SSH "sudo journalctl -u dnsmasq $SCOPE -q \
    | grep -oE 'query\[(A|AAAA)\] [^ ]+' | awk '{print \$2}' | sed 's/\.\$//' \
    | sort | uniq -c | sort -rn")
QUERIED_BOOT=$($SSH "sudo journalctl -u dnsmasq -b -q \
    | grep -oE 'query\[(A|AAAA)\] [^ ]+' | awk '{print \$2}' | sed 's/\.\$//' \
    | sort | uniq -c | sort -rn")
ALLOWED=$($SSH "awk -F/ '/^nftset=/{print \$2}' /etc/dnsmasq.conf")

[ -n "$BLOCKED" ] || { echo "nothing blocked by nftables $SCOPE_LABEL — nothing to suggest"; exit 0; }
echo "blocked dsts $SCOPE_LABEL ($(( $(echo "$BLOCKED" | wc -w) ))): $(echo "$BLOCKED" | tr '\n' ' ')"
[ -n "$QUERIED_BOOT" ] || { echo "dnsmasq query log empty this boot (log-queries off?) — cannot name any block; use the PTR tier below"; }

# candidate names = queried this boot (window or before), not covered by the
# live allow list (dnsmasq /domain/ semantics cover subdomains)
CANDS=""
for name in $( (echo "$QUERIED_WIN"; echo "$QUERIED_BOOT") | awk '$0 ~ /^ *[0-9]+ [^ ]+$/ {print $2}' | sort -u ); do
    covered=0
    for d in $ALLOWED; do
        case "$name" in "$d"|*".$d") covered=1; break ;; esac
    done
    [ "$covered" = 0 ] && CANDS="$CANDS $name"
done

MATCHLINES=""; MATCHNAMES=""; MATCHIPS=""
name=""; ips=""
qcount() { echo "$1" | awk -v n="$name" '$2==n {print $1; exit}'; }
flush() {   # emit the entry that just ended (once per name, unlike a naive
            # per-IP-line emit which duplicates entries). A name whose current
            # IPs match nothing blocked is simply skipped: it explains no
            # deny, so it is not a suggestion (old "queried but no IP match"
            # tier was hundreds of historical names of pure noise).
    [ -n "$name" ] || return 0
    hitips=""
    for i in $ips; do echo "$BLOCKED" | grep -qx "$i" && hitips="$hitips $i"; done
    if [ -n "$hitips" ]; then
        cntw=$(qcount "$QUERIED_WIN"); cntw=${cntw:-0}
        cnta=$(qcount "$QUERIED_BOOT"); cnta=${cnta:-0}
        if [ "$cntw" != 0 ]; then lab="$cntw queries"
        else lab="$cnta queries before window"
        fi
        # leading \n: command substitution strips trailing newlines, so
        # append-entries-with-leading-\n keeps one entry per line;
        # "name|" prefix lets the FINAL filter extract the name unambiguously
        MATCHLINES="$MATCHLINES
$name|$(printf '   %-48s %28s  blocked: %s' "$name" "($lab)" "$(echo $hitips | tr ' ' ',')")"
        MATCHNAMES="$MATCHNAMES $name"
        MATCHIPS="$MATCHIPS $hitips"
    fi
    name=""; ips=""
}
if [ -n "$CANDS" ]; then
    # resolve each candidate through the shield's dnsmasq (same answer the
    # agent got) and intersect with the blocked dsts: one ssh round-trip all.
    RES=$($SSH "for n in$CANDS; do echo \"N:\$n\"; dig +short A \$n @127.0.0.1 | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}\$'; done")
    while read -r line; do
        case "$line" in
            N:*) flush; name=${line#N:} ;;
            *)   ips="$ips $line" ;;
        esac
    done <<< "$RES"
    flush
fi

# collapse subdomains: dnsmasq /domain/ allow semantics mean allowing vg.no
# also covers www.vg.no, cmp.vg.no, ... — suggest only the shortest covering
# name.
FINAL=""
for n in $MATCHNAMES; do
    covered=0
    for m in $MATCHNAMES; do
        [ "$n" != "$m" ] && case "$n" in *".$m") covered=1; break ;; esac
    done
    [ "$covered" = 0 ] && FINAL="$FINAL $n"
done

echo
if [ -n "$FINAL" ]; then
    echo "blocking these (queried names whose current IPs match blocked dsts; subsumed subdomains collapsed):"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        n=${l%%|*}
        for f in $FINAL; do [ "$n" = "$f" ] && { echo "${l#*|}"; break; }; done
    done <<< "$MATCHLINES"
    echo
    echo "to allow — copy/paste:"
    echo "  ./shield-allow.sh $ID $FINAL"
fi

# every blocked IP no attributed name explains: name the owner via PTR so the
# operator can allow that domain (bare-IP allow is impossible by design).
REM=""
for ip in $BLOCKED; do
    seen=0
    for m in $MATCHIPS; do [ "$ip" = "$m" ] && { seen=1; break; }; done
    [ "$seen" = 0 ] && REM="$REM $ip"
done
if [ -n "$REM" ]; then
    echo
    echo "unattributed blocked IPs (no queried name resolves to them: agent cached"
    echo "the answer earlier, direct-IP traffic, or RRset rotated) — owner hint:"
    $SSH "for ip in$REM; do p=\$(dig -x \$ip +short @127.0.0.1 | head -1); printf '   %-16s %s\n' \$ip \"\${p:-no PTR}\"; done"
    echo "allow the OWNING domain (bare IPs are garbage-collected from allow4 by"
    echo "keepalive — the profile is domain-based):"
    echo "  ./shield-allow.sh $ID <domain from the hint you trust>"
fi
