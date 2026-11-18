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
./deploy-local.sh    # env overrides: VCPUS MEMORY_MB ROOT_DISK_GB STORAGE_GB IMAGE_URL SHIELD
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

## Network shield (agent sandbox)

The agent VM runs an autonomous AI agent **with sudo** — anything enforced
inside that VM can be undone by the agent itself. So the network guard lives
**outside** it: `deploy-local.sh` (default `SHIELD=ubuntu`) deploys a second
tiny VM as the agent's only way to the internet. The filter layers below are
numbered **F1–F4** ("F" for filter — reserving L1–L4 for the OSI model, where
IP/port filtering sits at network/transport and DNS at the application layer).

```
 internet ⇄ libvirt "default" NAT ⇄ [shield VM  wan0
                                     shield      lan0 10.99.N.2]
                                     ⇄ isolated net agentbox-N (no DHCP, no NAT) ⇄
                                     [agent VM 10.99.N.10, default route -> .2]
```

- **Why not inside the agent VM:** its sudo can rewrite iptables/netplan/DNS.
  Hypervisor-level L2 isolation (separate libvirt network) and a second VM are
  out of reach from the guest. This is also exactly what NREC security groups
  do in the OpenStack variant (rules enforced on the hypervisor).
- **Shield Profiles**: one plain-text allowlist
  per profile in `shield/profile-<name>.txt`, chosen with `SHIELD=<name>`;
  `SHIELD=none` = plain NAT (no shield). 
- **F1 (IP/port):** nftables on the shield: forward `policy drop`; only web
  (TCP 80/443, QUIC UDP 443) and NTP **to IPs that DNS approved**; masquerade.
- **F2 (DNS/host):** the shield's dnsmasq is the agent's only resolver; each
  profile domain gets an `nftset=` line that mirrors its resolved IPs into the
  nft `allow4` set (TTL-expiring). All other destinations fail closed.
  (DNS is the naming layer, not the blocklist: arbitrary names still resolve —
  connecting to an IP that never entered `allow4` is what fails.)
  Freshness is deterministic, not traffic-driven: `shield-keepalive.timer`
  (every 4 min) re-resolves each profile domain via the local dnsmasq and
  resets every `allow4` element's 30-min timer (`nft delete` + `nft add`,
  separate calls — one quoted nft string with an embedded `2>/dev/null` is a
  syntax error inside nft itself and silently no-ops); `min-cache-ttl=1800`
  stops dnsmasq re-mirrors from downgrading entries to short record TTLs.
  Without this: long-TTL domains (e.g. ~48-min TTL) lapse after 30 min —
  cached answers never trigger a re-mirror — so allowlisted access would
  silently die; stale round-robin IPs simply age out.
- **Legible denials (agents must be able to reason about them):**
  non-allowlisted connections are **rejected** (RST / port-unreachable) —
  instant, visible errors the agent's own tools report — not silent timeouts.
  Every query and denial is logged, and `sudo shield-report` on the shield
  prints a one-screen audit (nft counters, live allowlist, recent denies, top
  DNS queries, active flows). A domain in the log + refused = "profile
  `ubuntu` does not allow this host; ask the operator".
- **Monitoring:** `sudo shield-report` on demand; a systemd timer snapshots it
  every 10 min (`journalctl -u shield-monitor`) — NIST AI RMF "measure/
  monitor": visibility into agent network behavior, tamper-evident because the
  logs live on the shield VM, not the agent VM.

Operator access: agent SSH from the host as before (`10.99.N.10`, L2 direct);
shield SSH `ssh -i keys/<id>.pem ubuntu@10.99.N.2`; agent cannot SSH into the
shield (nft input rule).

**Applying profile changes:**
- Next deploy: just edit `shield/profile-<name>.txt`.
- Live (no VM redeploy/restart): `./shield-allow.sh <id> <domain> [domain…]`
  — appends the `nftset=` line to the shield's dnsmasq.conf AND the profile,
  then restarts the dnsmasq *service* (~2 s; kernel conntrack/nft survive so
  established agent connections are unaffected, only resolution pauses) and
  **primes `allow4`**: resolves through the shield's dnsmasq and adds the IPs
  manually (full 30-min timer), so the agent VM can curl the domain the
  second the script finishes — the keepalive timer then keeps it alive as
  long as the domain stays in the profile.
  `--revoke` is the mirror: it removes the dnsmasq line + profile entry and
  kills every live `allow4` entry for the domain (digging BOTH resolver views
  — dnsmasq's cache and upstream — since round-robin/CDN rotation means one
  view alone misses IPs agents already hold) and flushes their conntrack
  flows, so established browser connections die within seconds instead of
  riding the stateful path until the tab closes. Stale RRset generations that
  no current dig can rediscover are garbage-collected by the keepalive timer
  (≤4 min): any element no profile domain currently answers with is deleted.
  Restart not reload: dnsmasq(8) — "SIGHUP does NOT re-read the configuration
  file." CNAME'd domains need their target listed too (see profile comment).
  IP-granularity limit, made visible once: a revoked domain that shares IPs
  with a still-allowed one (nevron.no shares Canonical CDN IPs published in
  `old-releases.ubuntu.com`'s current RRset) keeps those IPs in `allow4`
  legitimately — content is then only stopped by TLS cert mismatch, not by
  the firewall. Truly cutting such a site = F3 egress proxy (see gaps).
- **Which domains to allow?** `./shield-suggest.sh <id>` — each manual run
  reports ALL traffic nftables blocked (windowed by `--since`, default this
  boot) and makes every blocked dst actionable:
  1. queried, not-yet-allowed names whose current IPs (resolved via the
     shield's own dnsmasq, same answer the agent got) match blocked dsts —
     one copy/paste `shield-allow.sh` line, subsumed subdomains collapsed;
     names queried *before* the window qualify too (a page resolves early,
     its connections get denied later) and are labelled as such
  2. blocked IPs no queried name explains → reverse-DNS (PTR) owner hint;
     allow that DOMAIN — bare IPs are GC'd from `allow4` by keepalive, the
     profile is domain-based by design
  Nothing is allowed automatically. Re-run after allowing: allowed names
  drop out. Needs the deny-log rate limit generous enough for browsing
  bursts (60/min in the template) or the snapshot is incomplete.
- **Re-apply a profile:** `./shield-apply.sh <id>` (SHIELD=<profile> as usual)
  — diffs the live dnsmasq `nftset=` lines against `shield/profile-<name>.txt`
  and makes live EXACTLY equal to the file: revokes drift first (fail-closed),
  then adds missing, both as single batched `shield-allow.sh` calls. Re-running
  is a no-op (CNAME targets live in the profile too). Caveat: the profile FILE
  is the source of truth — live allows made by hand on the host are wiped by an
  apply unless they were recorded in the same profile file your copy reads
  (host sync-dir and the Termux repo are separate copies: profile edits in one
  are invisible/overwritten by the other).

**Verified on local KVM (2026-11-17, `deploy-local.sh`/`destroy-local.sh`):**
full lifecycle passes — shield + agent cloud-init `errors: []`; agent DNS is
only the shield's dnsmasq (`10.99.N.2`); allowed host through the shield
returns 200; non-allowlisted domain rejected instantly (curl rc=7); direct-IP
bypass blocked; `allow4` self-populates with TTLs; `shield-report` and the
`shield-monitor` timer active; survives a shield reboot (udev renames land at
coldplug, nft rules reloaded via enabled `nftables.service`, dnsmasq active).

**Deliberate gaps** (each is a documented next layer, not an oversight):
- F3 (URL path/content, WAF-ish): DNS+IP allowlisting is host-granular.
  Path-level + HTTP(S)-content control needs an explicit egress proxy on the
  shield (mitmproxy/Squid + CA trust in the agent image) — biggest remaining
  complexity (CA distribution, QUIC, cert pinning), so deferred.
- F4 (agent-level monitoring): run [AgentSight](https://github.com/eunomia-bpf/agentsight)
  (eBPF: LLM API calls + kernel-level actions) *inside* the agent VM, shipping
  logs to the shield; plus endpoint HIDS (Wazuh). On-VM agents are
  monitoring/early-warning, not enforcement — sudo can tamper with them;
  enforcement stays on the shield.
- The agent can always DoS *itself* (its own bandwidth/DNS) — sandboxing is
  about containment of egress, not availability guarantees.

**OpenStack translation (main branch):** the same sandbox profile maps to
security-group rules (hypervisor-enforced, like the shield) — full universal
rule set, Terraform/CLI recipes and verified endpoint CIDR slots in
[`shield/README.md`](shield/README.md). In short: revoke the default
allow-all egress rule, add stateful egress for DNS/NTP and TCP 443 to
mirror/gpt.uio.no CIDRs. Coarser (no domain→IP mirroring, no DNS log), but
zero extra VMs — a `network_profile` variable + secgroup rules in `main.tf`
when translating. Full DNS-allowlist parity there needs a shield/router VM
with a floating IP (FWaaS or nftables on it).

Tear down: `./destroy-local.sh <id>`
