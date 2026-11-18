#!/bin/bash
# destroy-local.sh — tear down a deploy-local.sh deployment: agent VM + network
# shield (domains, disks, seeds, keys) and the isolated agentbox network when
# no defined domain still references it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ID="${1:?usage: destroy-local.sh <deployment_id>}"
case "$ID" in vps-local-*) : ;; *) echo "refusing to touch non-local id: $ID"; exit 1 ;; esac

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# re-derive shield addressing (same formula as deploy-local.sh)
OCTET=$(( 16#${ID: -2} % 239 + 1 ))
BOX="agentbox-$OCTET"

$SUDO virsh destroy "$ID" 2>/dev/null || true
$SUDO virsh destroy "$ID-shield" 2>/dev/null || true
$SUDO virsh undefine "$ID" 2>/dev/null || true
$SUDO virsh undefine "$ID-shield" 2>/dev/null || true
$SUDO rm -rf "/var/lib/libvirt/images/$ID"
rm -f "keys/$ID.pem" "keys/$ID.pem.pub" "keys/$ID.password"
rm -f "vm/$ID.user-data" "vm/$ID.meta-data" "vm/$ID.network-config" \
      "vm/$ID-shield.user-data" "vm/$ID-shield.meta-data" "vm/$ID-shield.network-config"
rmdir vm 2>/dev/null || true

# only undefine the shared network if nothing references it anymore
in_use=0
for dom in $($SUDO virsh list --all --name 2>/dev/null); do
    [ -n "$dom" ] || continue
    $SUDO virsh domiflist "$dom" 2>/dev/null | grep -q "$BOX" && { in_use=1; break; }
done
if [ "$in_use" -eq 0 ]; then
    $SUDO virsh net-destroy "$BOX" 2>/dev/null || true
    $SUDO virsh net-undefine "$BOX" 2>/dev/null || true
fi
echo "Destroyed $ID (+ shield, + $BOX if unused)"
