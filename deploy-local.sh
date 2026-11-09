#!/bin/bash
# deploy-local.sh — local KVM variant of deploy.sh (no Terraform, no OpenStack).
# Builds the same Ubuntu 24.04 desktop VM on this host via libvirt:
#   cloud image qcow2 + cloud-init.yaml.tftpl (rendered with sed) + NoCloud seed ISO.
# Requires (Ubuntu 24.04): sudo apt install qemu-kvm libvirt-daemon-system \
#   libvirt-clients cloud-image-utils virtinst wget
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# --- config (mirrors deploy.sh / terraform.tfvars) ---
VCPUS=${VCPUS:-4}
MEMORY_MB=${MEMORY_MB:-8192}                 # c1.xlarge equivalent
ROOT_DISK_GB=${ROOT_DISK_GB:-40}
STORAGE_GB=${STORAGE_GB:-20}                 # second disk -> /vault (00-storage.sh)
ADMIN_USER=${ADMIN_USER:-ubuntu}
SSH_USER=${SSH_USER:-ubuntu}
LOCAL_RDP_PORT=${LOCAL_RDP_PORT:-33389}
IMAGE_URL=${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
IMG_DIR=/var/lib/libvirt/images              # AppArmor-safe location for guest disks
DEPLOYMENT_ID="vps-local-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \\n' | head -c 6)"
VM_DIR="$IMG_DIR/$DEPLOYMENT_ID"
KEY="keys/$DEPLOYMENT_ID.pem"
PASSFILE="keys/$DEPLOYMENT_ID.password"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# --- preflight ---
[ -e /dev/kvm ] || { echo "ERROR: /dev/kvm missing — enable virtualization in BIOS"; exit 1; }
missing=()
for c in virt-install virsh cloud-localds qemu-img ssh-keygen wget sed awk; do
    command -v "$c" >/dev/null || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing commands: ${missing[*]}"
    echo "Install: sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients cloud-image-utils virtinst wget"
    exit 1
fi
$SUDO virsh net-start default 2>/dev/null || true
$SUDO virsh net-autostart default 2>/dev/null || true

# --- credentials (same convention as Terraform: keys/<id>.pem + .password) ---
mkdir -p keys
ssh-keygen -q -t ed25519 -N '' -C "$DEPLOYMENT_ID" -f "$KEY"
# 24 chars, alphanumeric + the same specials Terraform's random_password used
while :; do
    ADMIN_PASSWORD=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9!@#%^*()_+=-' | head -c 24)
    [ "${#ADMIN_PASSWORD}" -ge 24 ] && break
done
printf '%s' "$ADMIN_PASSWORD" > "$PASSFILE"
chmod 600 "$PASSFILE"

# --- render cloud-init (same templatefile substitutions as main.tf) ---
# In .tftpl every ${var} is Terraform-interpolated, bash ${VAR} included, so a
# literal-token sed reproduces templatefile() exactly.
# 'render' group: only created by the NVIDIA driver on the GOLD image; on a plain
# cloud image useradd -G render fails and the admin user is never created. Drop it.
# Escape \ & | for the sed replacement side (delimiter is |).
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g'; }
mkdir -p vm
sed -e "s/\${admin_user}/$ADMIN_USER/g" \
    -e "s|\${admin_password}|$(esc "$ADMIN_PASSWORD")|g" \
    -e "s|\${ssh_public_key}|$(esc "$(cat "$KEY.pub")")|g" \
    -e "s/groups: render, video, sudo/groups: video, sudo/" \
    cloud-init.yaml.tftpl > "vm/$DEPLOYMENT_ID.user-data"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$DEPLOYMENT_ID" "$DEPLOYMENT_ID" \
    > "vm/$DEPLOYMENT_ID.meta-data"

# --- disks: base image, root copy, secondary storage, NoCloud seed ---
$SUDO test -f "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" || \
    $SUDO wget -q -O "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" "$IMAGE_URL"
$SUDO mkdir -p "$VM_DIR"
$SUDO cp "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" "$VM_DIR/root.qcow2"
$SUDO qemu-img resize "$VM_DIR/root.qcow2" "${ROOT_DISK_GB}G" >/dev/null
$SUDO qemu-img create -f qcow2 "$VM_DIR/storage.qcow2" "${STORAGE_GB}G" >/dev/null
$SUDO mkdir -p "$VM_DIR/seed"
# cloud-localds wants literal seed/user-data + seed/meta-data names, not the
# source basenames (cp-to-dir default) — copy with explicit destination names.
$SUDO cp "vm/$DEPLOYMENT_ID.user-data" "$VM_DIR/seed/user-data"
$SUDO cp "vm/$DEPLOYMENT_ID.meta-data" "$VM_DIR/seed/meta-data"
rm -f "vm/$DEPLOYMENT_ID.user-data"          # contains password+key: remove from repo
$SUDO cloud-localds "$VM_DIR/seed.iso" "$VM_DIR/seed/user-data" "$VM_DIR/seed/meta-data"

# --- boot (NAT network only: no security group needed, VM is host-local) ---
echo "Deploying $DEPLOYMENT_ID (${VCPUS} vCPU, ${MEMORY_MB} MB, root ${ROOT_DISK_GB}G + storage ${STORAGE_GB}G)..."
$SUDO virt-install --name "$DEPLOYMENT_ID" --memory "$MEMORY_MB" --vcpus "$VCPUS" \
    --disk path="$VM_DIR/root.qcow2",format=qcow2,bus=virtio \
    --disk path="$VM_DIR/storage.qcow2",format=qcow2,bus=virtio \
    --disk path="$VM_DIR/seed.iso",device=cdrom,readonly=on \
    --network network=default,model=virtio \
    --osinfo detect=on,require=off \
    --graphics none --video virtio --import --noautoconsole

# --- resolve guest IPv4 from the libvirt DHCP lease ---
# The lease table prints a header whose $5 is literally "Protocol", and leases
# of destroyed VMs linger — so neither blank/wildcard matching nor "first
# match" is safe. Match the row by hostname (cloud-init sets local-hostname =
# DEPLOYMENT_ID, visible in net-dhcp-leases), extract the IP column
# position-independently; MAC regex from domiflist is the fallback.
lease_lookup() {
    $SUDO virsh net-dhcp-leases default 2>/dev/null | awk -v k="$1" '
        index($0,k) { for (i=1;i<=NF;i++) if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/|$)/) { sub(/\/.*/,"",$i); print $i } }'
}
IP=""
for _ in $(seq 1 60); do
    IP=$(lease_lookup "$DEPLOYMENT_ID")
    [ -z "$IP" ] || break
    MAC=$($SUDO virsh domiflist "$DEPLOYMENT_ID" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    [ -z "$MAC" ] || IP=$(lease_lookup "$MAC")
    [ -z "$IP" ] || break
    sleep 5
done
[ -n "$IP" ] || { echo "ERROR: no DHCP lease for $DEPLOYMENT_ID — check: virsh net-dhcp-leases default"; exit 1; }

# --- wait for cloud-init (same as null_resource.wait_for_cloud_init) ---
echo "VM up at $IP — waiting for cloud-init (up to 15 min)..."
until ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -i "$KEY" "$SSH_USER@$IP" 'cloud-init status --wait --long' 2>/dev/null; do
    [ "$SECONDS" -lt 900 ] || { echo "ERROR: cloud-init not done after 15 min"; exit 1; }
    sleep 10
done

# --- outputs (mirrors outputs.tf) ---
echo ""
echo "Deployment:      $DEPLOYMENT_ID"
echo "VM IPv4 (NAT):   $IP"
echo "Disks:           $VM_DIR/"
echo "SSH private key: $KEY"
echo "Admin password:  $PASSFILE"
echo "SSH:             ssh -i $KEY $SSH_USER@$IP"
echo "RDP (from host): $IP:3389"
echo "RDP (remote op): ssh -L $LOCAL_RDP_PORT:$IP:3389 <this-host>, then RDP client -> localhost:$LOCAL_RDP_PORT"
