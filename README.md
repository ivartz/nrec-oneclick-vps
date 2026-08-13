# NREC VPS — One-Click OpenStack Deployment

Ubuntu 24.04 LTS VPS on NREC OpenStack with GNOME desktop (TurboVNC) and Chromium. Terraform + cloud-init only.

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
sudo -u ubuntu /opt/TurboVNC/bin/vncserver :1
```

Default session is GNOME Flashback (Metacity). For modern GNOME:

```bash
sudo -u ubuntu /opt/TurboVNC/bin/vncserver :1 -wm gnome
```

Connect VNC via tunnel:
```bash
ssh -L 55901:localhost:5901 -i keys/<id>.pem ubuntu@<ip>
# vncviewer localhost:55901
```

End VNC session:
```bash
sudo -u ubuntu /opt/TurboVNC/bin/vncserver -kill :1
```

Passwords (all the same):
- VNC password: `cat keys/<id>.vncpass` (local)
- On VM: `cat /home/ubuntu/.vnc-passwd` or `cat /home/ubuntu/.admin-password`

## Additional sessions

Session 2:
```bash
ssh -L 55902:localhost:5902 -i keys/<id>.pem ubuntu@<ip>
sudo -u ubuntu /opt/TurboVNC/bin/vncserver :2
```

Session 3:
```bash
ssh -L 55903:localhost:5903 -i keys/<id>.pem ubuntu@<ip>
sudo -u ubuntu /opt/TurboVNC/bin/vncserver :3
```

## Network

- NREC IPv6 network (public IPv6, private IPv4) or dualStack fallback
- SSH ingress locked to operator IP
- No floating IPs, no public VNC ports

## Tear down

```bash
terraform destroy
```
