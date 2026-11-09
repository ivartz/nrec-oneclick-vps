# NREC VPS — One-Click OpenStack Deployment

Ubuntu 24.04 LTS VPS on NREC OpenStack with GNOME desktop (TurboVNC) and Google Chrome. Terraform + cloud-init only.

## Prerequisites

- Terraform >= 1.5
- NREC OpenStack credentials
- SSH + VNC client

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
vncserver :1
```

Default session is GNOME Flashback (Metacity). For modern GNOME:

```bash
vncserver :1 -wm gnome
```

Connect VNC via tunnel:
```bash
ssh -L 55901:localhost:5901 -i keys/<id>.pem ubuntu@<ip>
# vncviewer localhost:55901
```

End VNC session:
```bash
vncserver -kill :1
```

Passwords (all the same):
- On VM: `cat /home/ubuntu/.vnc-passwd`
- Local copy: `cat keys/<id>.vncpass`

## Network

- NREC IPv6 network (public IPv6, private IPv4) or dualStack fallback
- SSH ingress locked to operator IP
- No floating IPs, no public VNC ports

## Storage

A 50 GB `mass-storage-default` Cinder volume is attached as the second disk
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
  and mounted at `/vault`, TurboVNC (start with `vncserver :1`), GNOME Flashback session
- Network: libvirt default NAT — VM IPv4 reachable from the host only, so the
  operator-IP security group is unnecessary; VNC: `vncviewer <vm-ip>:5901` from the host,
  `ssh -L 55901:<vm-ip>:5901 <host>` + `vncviewer localhost:55901` for remote operators
- vs GOLD image: `render` group dropped from the user config (it only exists
  once an NVIDIA driver creates it; `useradd -G render` would fail otherwise)

Tear down: `./destroy-local.sh <id>`
