#!/bin/bash
# destroy-local.sh — tear down a deploy-local.sh VM (domain, disks, keys).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ID="${1:?usage: destroy-local.sh <deployment_id>}"
case "$ID" in vps-local-*) : ;; *) echo "refusing to touch non-local id: $ID"; exit 1 ;; esac

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO virsh destroy "$ID" 2>/dev/null || true
$SUDO virsh undefine "$ID" 2>/dev/null || true
$SUDO rm -rf "/var/lib/libvirt/images/$ID"
rm -f "keys/$ID.pem" "keys/$ID.pem.pub" "keys/$ID.password"
rm -f "vm/$ID.user-data" "vm/$ID.meta-data"   # deploy scratch seed files
rmdir vm 2>/dev/null || true
echo "Destroyed $ID"
