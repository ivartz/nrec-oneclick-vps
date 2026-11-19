#!/bin/bash
# shield-apply.sh — re-apply a profile to a RUNNING shield: makes the live
# dnsmasq nftset= set EXACTLY equal to shield/profile-$SHIELD.txt (default
# ubuntu; SHIELD=<profile> as in deploy-local.sh/shield-allow.sh), without
# redeploying anything. Thin diff over shield-allow.sh — no new mechanism:
#   live domains  = the shield's /etc/dnsmasq.conf nftset= lines
#   wanted        = the profile file (comments/blank lines ignored)
#   drift         = revocations FIRST (fail-closed: shrink the allow window
#                   before widening it), then additions — one batched call
#                   each (each shield-allow.sh run restarts dnsmasq once).
# Re-applying the same profile is a no-op: CNAME targets that shield-allow.sh
# auto-adds to conf are recorded in the profile too, so they never count as
# drift. Known quirk: --revoke is CNAME-symmetric and also removes the
# canonical target from the profile FILE; if a dropped domain CNAMEs onto a
# name the target profile allows in its own right, that line is lost from the
# file — re-run apply to restore it (rare enough not to complicate the diff).
# Usage: ./shield-apply.sh <deployment-id>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # keys/ and shield/ are relative to THIS dir
ID=${1:?usage: shield-apply.sh <deployment-id>}
SHIELD=${SHIELD:-ubuntu}
[[ "$SHIELD" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'ERROR: invalid profile name' >&2; exit 1; }
PROFILE="shield/profile-$SHIELD.txt"
[ -f "$PROFILE" ] || { echo "ERROR: no $PROFILE"; exit 1; }
[ -f "keys/$ID.pem" ] || { echo "ERROR: no keys/$ID.pem — run from the deploy dir"; exit 1; }
source shield/validation.sh
WANT=$(profile_domains "$PROFILE")
source shield/connection.sh
LIVE=$(live_domains)
LIVE=$(printf '%s\n' "$LIVE" | sort -u)
WANT=$(printf '%s\n' "$WANT" | sort -u)
ADD=$(comm -13 <(echo "$LIVE") <(echo "$WANT"))
DROP=$(comm -23 <(echo "$LIVE") <(echo "$WANT"))

if [ -n "$DROP" ]; then
    echo "revoking (live on $GW but not in $PROFILE):"; echo "$DROP" | sed 's/^/  /'
    SHIELD=$SHIELD ./shield-allow.sh --revoke "$ID" $DROP
fi
if [ -n "$ADD" ]; then
    echo "adding (in $PROFILE but not live on $GW):"; echo "$ADD" | sed 's/^/  /'
    SHIELD=$SHIELD ./shield-allow.sh "$ID" $ADD
fi
if [ -z "$ADD$DROP" ]; then
    echo "already applied: live conf == $PROFILE ($(echo "$WANT" | wc -w) domains)"
fi
