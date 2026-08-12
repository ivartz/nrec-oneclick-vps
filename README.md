# Hermes VPS — One-Click OpenStack Deployment

Ubuntu 24.04 LTS VPS on NREC OpenStack with GNOME desktop (TurboVNC), Hermes Desktop, Chromium, and Obsidian. Terraform + cloud-init only.

## Prerequisites

- Terraform >= 1.5
- NREC OpenStack credentials
- SSH + VNC client

## Deploy

All:

```bash
[git clone repo https url]
git checkout hermes
```

Linux, macOS, Termux:

```bash
cp env.sh.template env.sh   # fill in credentials
./deploy.sh
```
Termux: `deploy.sh` auto-starts `https_proxy.py` (DNS workaround) and uses the offline provider mirror.

Windows:

```bash
cp env.ps1.template env.ps1 # fill in credentials
powershell -ExecutionPolicy Bypass -File deploy.ps1`
```
TODO: Missing env.ps1.template

Logs can found in VM at /var/log/hermes-vps and /home/hermes/.vnc

## After deploy

```bash
ssh -i keys/<id>.pem ubuntu@<ip>
sudo -u hermes /opt/TurboVNC/bin/vncserver :1
```

The default session is GNOME Flashback (Metacity) — a lightweight classic
desktop. To use the modern GNOME desktop instead, pass `-wm gnome`:

```bash
sudo -u hermes /opt/TurboVNC/bin/vncserver :1 -wm gnome              # modern GNOME
sudo -u hermes /opt/TurboVNC/bin/vncserver :1 -wm gnome-flashback-metacity  # flashback (default)
```

Connect VNC via tunnel:
```bash
ssh -L 55901:localhost:5901 -i keys/<id>.pem ubuntu@<ip>
# vncviewer localhost:55901
```

Start chromium for testing (from VNC session):
```bash
chromium --no-sandbox
```

End VNC session:
```bash
sudo -u hermes /opt/TurboVNC/bin/vncserver -kill :1
```

Passwords (all the same):
- VNC password: `cat keys/<id>.vncpass` (local)
- On VM: `cat /home/ubuntu/.vnc-passwd` or `cat /home/hermes/.admin-password`

## Verify

```bash
which obsidian
which chromium
hermes --version
```

## Network

- NREC IPv6 network (public IPv6, private IPv4) or dualStack fallback
- SSH-only ingress, locked to operator IP
- No floating IPs, no public VNC ports

## Tear down

```bash
terraform destroy
```
