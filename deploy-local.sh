#!/bin/bash
# deploy-local.sh — local KVM variant of deploy.sh (no Terraform, no OpenStack).
# Builds the same Ubuntu 24.04 desktop VM on this host via libvirt:
#   cloud image qcow2 + cloud-init.yaml.tftpl (rendered with sed) + NoCloud seed ISO.
#
# Network shield (SHIELD=sandbox, default; SHIELD=none = old plain-NAT flow):
# the agent VM is fronted by a second tiny "shield" VM. The agent sits on an
# isolated libvirt network (agentbox-<n>: no DHCP, no NAT, forward=none) whose
# only way out is the shield: default-deny egress (nftables) + DNS allowlist
# (dnsmasq nftset) from shield/profile-<profile>.txt, legible REJECTs so the
# agent can reason about denials, and an audit report (sudo shield-report).
# Why a second VM: the agent has sudo on its own box and could undo any
# firewall inside it; L2 isolation + the shield VM are out of its reach.
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
LOCAL_VNC_PORT=${LOCAL_VNC_PORT:-55901}      # matches terraform local_vnc_port
TURBOVNC_DEB_URL=${TURBOVNC_DEB_URL:-https://github.com/TurboVNC/turbovnc/releases/download/3.3/turbovnc_3.3_amd64.deb}
IMAGE_URL=${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
SHIELD=${SHIELD:-sandbox}                    # profile name (shield/profile-*.txt) or none
IMG_DIR=/var/lib/libvirt/images              # AppArmor-safe location for guest disks
DEPLOYMENT_ID="vps-local-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \\n' | head -c 6)"
VM_DIR="$IMG_DIR/$DEPLOYMENT_ID"
KEY="keys/$DEPLOYMENT_ID.pem"
PASSFILE="keys/$DEPLOYMENT_ID.password"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# --- shield addressing: deterministic from the (random) id suffix so
#     destroy-local.sh can re-derive it. octet 1..239; two concurrent deploys
#     colliding on the octet (1/239) share the network but would clash on the
#     static agent IP — rare; destroy+redeploy fixes it. ---
SHIELD_ID="$DEPLOYMENT_ID-shield"
OCTET=$(( 16#${DEPLOYMENT_ID: -2} % 239 + 1 ))
BOX="agentbox-$OCTET"
BOX_HOST="10.99.$OCTET.1"    # libvirt bridge address on the host (operator side)
GW="10.99.$OCTET.2"          # shield lan0 iface: the agent's gateway + resolver
AGENT_IP="10.99.$OCTET.10"   # agent VM static address
mac_of() { local h; h=$(printf '%s' "$1" | md5sum | cut -c1-6)
           printf '52:54:00:%s:%s:%s' "${h:0:2}" "${h:2:2}" "${h:4:2}"; }
WAN_MAC=$(mac_of "$SHIELD_ID-wan"); LAN_MAC=$(mac_of "$SHIELD_ID-lan"); VM_MAC=$(mac_of "$DEPLOYMENT_ID")

# --- preflight ---
[ -e /dev/kvm ] || { echo "ERROR: /dev/kvm missing — enable virtualization in BIOS"; exit 1; }
missing=()
for c in virt-install virsh cloud-localds qemu-img ssh-keygen wget sed awk md5sum; do
    command -v "$c" >/dev/null || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing commands: ${missing[*]}"
    echo "Install: sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients cloud-image-utils virtinst wget"
    exit 1
fi
if [ "$SHIELD" != none ]; then
    PROFILE="shield/profile-$SHIELD.txt"
    [ -f "$PROFILE" ] || { echo "ERROR: no such shield profile: $PROFILE"; exit 1; }
    # one line, space-separated: a sed token must not inject newlines into the
    # YAML block scalar (cloud-init-shield.yaml.tftpl expands it in a bash for-loop)
    ALLOW_DOMAINS=$(sed 's/#.*//' "$PROFILE" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    [ -n "$ALLOW_DOMAINS" ] || { echo "ERROR: $PROFILE contains no domains"; exit 1; }
fi
$SUDO virsh net-start default 2>/dev/null || true
$SUDO virsh net-autostart default 2>/dev/null || true

# --- credentials (same convention as Terraform: keys/<id>.pem + .password;
#     the shield reuses this keypair+password: one operator identity, YAGNI) ---
mkdir -p keys
ssh-keygen -q -t ed25519 -N '' -C "$DEPLOYMENT_ID" -f "$KEY"
# 24 chars, alphanumeric + the same specials Terraform's random_password used
while :; do
    ADMIN_PASSWORD=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9!@#%^*()_+=-' | head -c 24)
    [ "${#ADMIN_PASSWORD}" -ge 24 ] && break
done
printf '%s' "$ADMIN_PASSWORD" > "$PASSFILE"
chmod 600 "$PASSFILE"

# --- render helpers ---
# In .tftpl every ${var} is Terraform-interpolated, bash ${VAR} included, so a
# literal-token sed reproduces templatefile() exactly.
# Escape \ & | for the sed replacement side (delimiter is |).
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g'; }
mkdir -p vm

# 'render' group: only created by the NVIDIA driver on the GOLD image; on a plain
# cloud image useradd -G render fails and the admin user is never created. Drop it.
render_agent() {
    sed -e "s/\${admin_user}/$ADMIN_USER/g" \
        -e "s|\${admin_password}|$(esc "$ADMIN_PASSWORD")|g" \
        -e "s|\${ssh_public_key}|$(esc "$(cat "$KEY.pub")")|g" \
        -e "s|\${turbovnc_deb_url}|$(esc "$TURBOVNC_DEB_URL")|g" \
        -e "s/groups: render, video, sudo/groups: video, sudo/" \
        cloud-init.yaml.tftpl > "vm/$DEPLOYMENT_ID.user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$DEPLOYMENT_ID" "$DEPLOYMENT_ID" \
        > "vm/$DEPLOYMENT_ID.meta-data"
}

# base image cache + disk helper (guest disks must live under IMG_DIR: AppArmor)
$SUDO test -f "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" || \
    $SUDO wget -q -O "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" "$IMAGE_URL"
new_disk() { $SUDO cp "$IMG_DIR/ubuntu-noble-cloudimg-amd64.img" "$1" && $SUDO qemu-img resize "$1" "$2" >/dev/null; }

# The lease table prints a header whose $5 is literally "Protocol", and leases
# of destroyed VMs linger — so neither blank/wildcard matching nor "first
# match" is safe. Match the row by hostname (cloud-init sets local-hostname),
# extract the IP column position-independently.
lease_lookup() {
    $SUDO virsh net-dhcp-leases default 2>/dev/null | awk -v k="$1" '
        index($0,k) { for (i=1;i<=NF;i++) if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/|$)/) { sub(/\/.*/,"",$i); print $i } }'
}

# wait for a VM's cloud-init over ssh; per-loop budget (not global SECONDS,
# which would expire early once the shield wait has already eaten it)
wait_cloud_init() {   # $1=ip  $2=label  $3=budget-seconds
    echo "Waiting for $1 ($2) cloud-init (up to $3 s)..."
    local start=$SECONDS
    until ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 -i "$KEY" "$SSH_USER@$1" 'cloud-init status --wait --long' 2>/dev/null; do
        [ $((SECONDS - start)) -lt "$3" ] || { echo "ERROR: $2 cloud-init not done after $3 s"; exit 1; }
        sleep 10
    done
}

# --- shield: isolated network + gateway VM, deployed BEFORE the agent VM ---
if [ "$SHIELD" != none ]; then
    if ! $SUDO virsh net-info "$BOX" >/dev/null 2>&1; then
        $SUDO virsh net-define /dev/stdin <<EOF
<network>
  <name>$BOX</name>
  <forward mode='none'/>
  <ip address='$BOX_HOST' netmask='255.255.255.0'/>
</network>
EOF
    fi
    $SUDO virsh net-start "$BOX" 2>/dev/null || true
    $SUDO virsh net-autostart "$BOX" 2>/dev/null || true

    $SUDO mkdir -p "$VM_DIR/shield-seed"
    new_disk "$VM_DIR/shield-root.qcow2" 8G
    sed -e "s/\${admin_user}/$ADMIN_USER/g" \
        -e "s|\${admin_password}|$(esc "$ADMIN_PASSWORD")|g" \
        -e "s|\${ssh_public_key}|$(esc "$(cat "$KEY.pub")")|g" \
        -e "s|\${lan_mac}|$LAN_MAC|g" \
        -e "s|\${wan_mac}|$WAN_MAC|g" \
        -e "s|\${box_host}|$BOX_HOST|g" \
        -e "s|\${allow_domains}|$(esc "$ALLOW_DOMAINS")|g" \
        cloud-init-shield.yaml.tftpl > "vm/$SHIELD_ID.user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$SHIELD_ID" "$SHIELD_ID" \
        > "vm/$SHIELD_ID.meta-data"
    # netplan renames the matched NICs; the nft/dnsmasq rules key off wan0/lan0
    cat > "vm/$SHIELD_ID.network-config" <<EOF
version: 2
ethernets:
  wan0:
    match: { macaddress: "$WAN_MAC" }
    dhcp4: true
  lan0:
    match: { macaddress: "$LAN_MAC" }
    addresses: [ $GW/24 ]
EOF
    # cloud-localds wants literal seed/user-data + seed/meta-data names, not the
    # source basenames (cp-to-dir default) — copy with explicit destination names.
    $SUDO cp "vm/$SHIELD_ID.user-data" "$VM_DIR/shield-seed/user-data"
    $SUDO cp "vm/$SHIELD_ID.meta-data" "$VM_DIR/shield-seed/meta-data"
    $SUDO cp "vm/$SHIELD_ID.network-config" "$VM_DIR/shield-seed/network-config"
    rm -f "vm/$SHIELD_ID.user-data"          # contains password+key: remove from repo
    $SUDO cloud-localds --network-config "$VM_DIR/shield-seed/network-config" \
        "$VM_DIR/shield-seed.iso" "$VM_DIR/shield-seed/user-data" "$VM_DIR/shield-seed/meta-data"

    echo "Deploying network shield $SHIELD_ID (profile $SHIELD)..."
    $SUDO virt-install --name "$SHIELD_ID" --memory 1024 --vcpus 1 \
        --disk path="$VM_DIR/shield-root.qcow2",format=qcow2,bus=virtio \
        --disk path="$VM_DIR/shield-seed.iso",device=cdrom,readonly=on \
        --network network=default,model=virtio,mac=$WAN_MAC \
        --network network="$BOX",model=virtio,mac=$LAN_MAC \
        --osinfo detect=on,require=off \
        --graphics none --video virtio --import --noautoconsole

    SHIELD_IP=""
    for _ in $(seq 1 60); do
        SHIELD_IP=$(lease_lookup "$SHIELD_ID")
        [ -n "$SHIELD_IP" ] && break
        sleep 5
    done
    [ -n "$SHIELD_IP" ] || { echo "ERROR: no DHCP lease for $SHIELD_ID — check: virsh net-dhcp-leases default"; exit 1; }
    wait_cloud_init "$SHIELD_IP" "shield" 1500
fi

# --- agent VM: disks + seed ---
render_agent
$SUDO mkdir -p "$VM_DIR/seed"
new_disk "$VM_DIR/root.qcow2" "${ROOT_DISK_GB}G"
$SUDO qemu-img create -f qcow2 "$VM_DIR/storage.qcow2" "${STORAGE_GB}G" >/dev/null
$SUDO cp "vm/$DEPLOYMENT_ID.user-data" "$VM_DIR/seed/user-data"
$SUDO cp "vm/$DEPLOYMENT_ID.meta-data" "$VM_DIR/seed/meta-data"
rm -f "vm/$DEPLOYMENT_ID.user-data"          # contains password+key: remove from repo

if [ "$SHIELD" != none ]; then
    # static netconfig: no DHCP exists on agentbox; default route + DNS -> shield
    cat > "vm/$DEPLOYMENT_ID.network-config" <<EOF
version: 2
ethernets:
  eth0:
    match: { macaddress: "$VM_MAC" }
    addresses: [ $AGENT_IP/24 ]
    routes:
      - to: default
        via: $GW
    nameservers:
      addresses: [ $GW ]
EOF
    $SUDO cp "vm/$DEPLOYMENT_ID.network-config" "$VM_DIR/seed/network-config"
    $SUDO cloud-localds --network-config "$VM_DIR/seed/network-config" \
        "$VM_DIR/seed.iso" "$VM_DIR/seed/user-data" "$VM_DIR/seed/meta-data"
    NET_ARGS=( --network network="$BOX",model=virtio,mac=$VM_MAC )
else
    $SUDO cloud-localds "$VM_DIR/seed.iso" "$VM_DIR/seed/user-data" "$VM_DIR/seed/meta-data"
    NET_ARGS=( --network network=default,model=virtio )
fi

# --- boot ---
echo "Deploying $DEPLOYMENT_ID (${VCPUS} vCPU, ${MEMORY_MB} MB, root ${ROOT_DISK_GB}G + storage ${STORAGE_GB}G)..."
$SUDO virt-install --name "$DEPLOYMENT_ID" --memory "$MEMORY_MB" --vcpus "$VCPUS" \
    --disk path="$VM_DIR/root.qcow2",format=qcow2,bus=virtio \
    --disk path="$VM_DIR/storage.qcow2",format=qcow2,bus=virtio \
    --disk path="$VM_DIR/seed.iso",device=cdrom,readonly=on \
    "${NET_ARGS[@]}" \
    --osinfo detect=on,require=off \
    --graphics none --video virtio --import --noautoconsole

# --- resolve agent IP: static when shielded, else wait for the DHCP lease ---
if [ "$SHIELD" != none ]; then
    IP="$AGENT_IP"
else
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
fi

# --- wait for cloud-init (same as null_resource.wait_for_cloud_init) ---
echo "VM up at $IP"
wait_cloud_init "$IP" "agent" 900

# --- outputs (mirrors outputs.tf) ---
echo ""
echo "Deployment:      $DEPLOYMENT_ID"
if [ "$SHIELD" != none ]; then
    echo "Shield:          $SHIELD_ID — profile $SHIELD, gateway $GW (VM IPv4: $SHIELD_IP)"
    echo "Shield SSH:      ssh -i $KEY $SSH_USER@$GW"
    echo "Shield audit:    ssh -i $KEY $SSH_USER@$GW sudo shield-report"
    echo "Egress profile:  $PROFILE"
fi
echo "VM IPv4:         $IP"
echo "Disks:           $VM_DIR/"
echo "SSH private key: $KEY"
echo "Admin password:  $PASSFILE"
echo "SSH:             ssh -i $KEY $SSH_USER@$IP"
echo "VNC: start on VM:  ssh -i $KEY $SSH_USER@$IP -X  then: vncserver :1"
echo "VNC (from host):   vncviewer $IP:5901"
echo "VNC (remote op):   ssh -L $LOCAL_VNC_PORT:$IP:5901 -i <op-key> <this-host> -X, then vncviewer localhost:$LOCAL_VNC_PORT"
