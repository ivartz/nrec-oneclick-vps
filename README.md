# NREC VPS — One-Click OpenStack Deployment

Ubuntu 24.04 LTS VPS on NREC OpenStack with GNOME Flashback (Metacity) desktop via xrdp/RDP and Google Chrome. Terraform + cloud-init only.

## Prerequisites

- Terraform >= 1
- NREC OpenStack credentials
- SSH client + RDP client (Remmina, rdesktop, Microsoft Remote Desktop, etc.)

## Deploy

Linux, macOS, Termux:

```bash
cp env.sh.template env.sh   # fill in credentials
./deploy.sh
```

Termux: `deploy.sh` auto-starts `https_proxy.py` (DNS workaround) and uses the offline provider mirror.

Windows:

```powershell
cp env.ps1.template env.ps1 # fill in credentials
powershell -ExecutionPolicy Bypass -File deploy.ps1
```

## After deploy

```bash
ssh -i keys/<id>.pem ubuntu@<ip>
```

The xrdp service starts automatically on boot. GNOME Flashback (Metacity) is the default session.

Connect RDP via SSH tunnel:

```bash
ssh -L 33389:localhost:3389 -i keys/<id>.pem ubuntu@<ip>
# Then connect with your RDP client to localhost:33389
```

Use the Linux password (`keys/<id>.password` locally, `~/.admin-password` on the VM) for RDP authentication. GNOME Flashback (Metacity) sessions persist on the server: disconnecting and reconnecting reattaches to the same session.

## Network

- NREC IPv6 network (public IPv6, private IPv4) or dualStack fallback
- SSH ingress locked to operator IP
- No floating IPs, no public RDP ports

## Storage

A 20 GB `mass-storage-default` Cinder volume is attached as the second disk
(`/dev/vdb` or `/dev/sdb` depending on image - detected dynamically), formatted
ext4 (label `vps-storage`), and mounted at `/vault`. Owned by `ubuntu` -
read/write out of the box. Mounted at boot via `/etc/fstab` with `nofail`, so
a missing volume never blocks boot.

## Tear down

```bash
terraform destroy
```

## Local KVM variant (no Terraform/OpenStack)

`deploy-local.sh` runs the same cloud-init stack (same `cloud-init.yaml.tftpl`,
rendered with sed instead of `templatefile()`) on a KVM guest on a standard
Ubuntu 24.04 Server host, via libvirt (`virt-install` + NoCloud seed ISO):

```bash
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients cloud-image-utils virtinst
./deploy-local.sh    # env overrides: VCPUS MEMORY_MB ROOT_DISK_GB STORAGE_GB IMAGE_URL
```

- Base image: official Ubuntu noble server cloud image, downloaded once to
  `/var/lib/libvirt/images/` (AppArmor-safe location for guest disks)
- Same artifacts: `keys/<id>.pem`, `keys/<id>.password`, second disk formatted
  and mounted at `/vault`, xrdp on 3389, GNOME Flashback session
- Network: libvirt default NAT — VM IPv4 reachable from the host only, so the
  operator-IP security group is unnecessary; RDP: `ssh -L 33389:<vm-ip>:3389 <host>`
- vs GOLD image: `render` group dropped from the user config (it only exists
  once an NVIDIA driver creates it; `useradd -G render` would fail otherwise)

Tear down: `./destroy-local.sh <id>`
