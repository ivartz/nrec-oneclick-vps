# Sandbox firewall rules — porting reference

Distillation of the universal rules for sandboxing an autonomous AI agent VM,
for implementing the shield/profile-* concept as **OpenStack security groups**
(main branch `deploy.sh`/Terraform) and, where needed, Neutron FWaaS or a
shield/router VM. Derived from the local KVM shield (`cloud-init-shield.yaml.tftpl`)
plus OWASP LLM Top 10 / OWASP Agentic Top 10 (2026) / NIST AI RMF threat framing:
the agent is an **untrusted workload with sudo** — egress is the primary attack
surface (exfiltration, C2, tool/registry supply-chain, browser exploits), the
agent VM itself is never the enforcement point.

## Universal rule set (profile-independent)

| # | Rule | Why (threat it closes) |
|---|------|------------------------|
| U0 | **No ingress** except TCP 22 from operator IP (/32 v4, /128 v6). No floating IP on the agent; keep IPv6 exposure paired with SG v6 rules. | RCE→botnet surface zero. Matches current `agent` group. |
| U1 | **Egress default-deny.** In Neutron: do NOT attach the `default` SG (it carries allow-all egress); attach only your custom group. A group with zero egress rules = deny all egress. Returns are stateful-allowed automatically. | Exfil/C2 by default; OWASP Agentic "tool misuse / excessive agency". |
| U2 | **DNS egress only to designated resolvers** (UDP+TCP 53): your shield, or pinned resolvers. Never 0.0.0.0/0. | Blocks DNS-tunnel exfil and allow-list bypass via rogue resolvers. |
| U3 | **NTP egress** (UDP 123) to designated pool. | Clock skew breaks TLS validity; cheap, low-risk exception. |
| U4 | **LLM egress (TCP 443, optionally UDP/443 QUIC) via an institutional gateway** (gpt.uio.no = one stable host). Avoid pinning "AI provider" ranges: hyperscaler APIs sit behind shared CDNs — the same IPs serve any attacker's webhook/pastebin, so a CDN allow = an exfil allow. | Keeps model access narrow, auditable, and gateway-logged (UiO already does auth/quota there). NIST AI RMF "control/monitor". |
| U5 | **OS/toolchain update egress** (80/443) to mirror ranges only (Ubuntu CDN, GitHub, Google). apt/GPG signatures still required — network allow narrows supply-chain to the authentic sources. | LLM08 supply chain; keeps agent patchable (long-running goal safety). |
| U6 | **Never allow egress to link-local/metadata** (169.254.169.254, fd00 metadata proxies) and **never to RFC1918/tenant/edu subtrees** (lateral movement). With U1 these are implicit — just *don't add* such egress rules. | user-data/credentials via metadata; pivot to other VMs/UiO network (UiO lead's "sperre mot resten av uio nett"). |
| U7 | **Block QUIC (UDP 443) whenever TLS content inspection (F3 filter layer) is on the roadmap**; allow it only in profiles that forgo inspection. | Browser QUIC bypasses HTTPS proxies. |
| U8 | **No egress:22 (git push/ssh-out) in `sandbox`**; opt-in slot in dev profiles. | Common exfil/tunnel channel. |
| U9 | **Everything else implicitly denied**; every deny should be *legible* to the agent (RST/reject + a lookup-able policy, as the KVM shield does) — plain SGs silently drop → agents see timeouts and retry-storm; mitigate by giving the agent the profile text (e.g. world-readable note in the image / a /policy page on the gateway). | "Understandable denies" requirement. |
| U10 | **Monitoring outside the agent VM**: DNS query log, per-rule counters, flow snapshots (KVM shield: `shield-report`). On OpenStack SGs give you none of this — see gaps. | NIST AI RMF "measure"; tamper-evidence vs a sudo agent. |

## Shield profiles

- **ubuntu**
- **feide**
- **uio-gpt**
- **hermes-uio-gpt**
- **TODO: uio-test**: + eduroam-scope inbound test ports, + UiO resolvers, egress
  within UiO-published ranges where needed, still deny-to-rest-of-UiO (U6).

## OpenStack implementation notes

- **Semantics**: SGs are stateful; attached groups' rules union; no rule order.
  Egress rules govern outbound; established replies automatic. IPv4 vs IPv6
  rules are separate (`ethertype`) — the NREC `dualStack`/`IPv6` networks make
  v6 pairs mandatory (public IPv6!).
- **Quota**: default ≈40 SG rules / project (`openstack quota show | grep -i security_group`).
  The ubuntu profile = ~10–15 destinations × 2 ethertypes → fits; check
  before adding long CDN pin-lists.
- **Attach ONLY the custom group** to the agent instance (`security_groups = [custom]`)
  — `default` must not be in the list (it allow-all egresses).
- Terraform, matching this repo's style — one rule per (cidr, proto, port,
  ethertype), expanded from profile lists:

  ```hcl
  variable "sandbox_egress" {
    type = list(object({ cidr = string, proto = string, port = number, v6 = bool }))
    default = []  # fill from profile slots; e.g. { "129.240.118.29/32","tcp",443,false }
  }
  resource "openstack_networking_secgroup_v2" "sandbox_egress" {
    name        = "${local.deployment_id}-egress"
    description = "Default-deny egress sandbox; explicit allows only."
  }
  resource "openstack_networking_secgroup_rule_v2" "egress" {
    for_each          = { for i, r in var.sandbox_egress : i => r }
    direction         = "egress"
    ethertype         = each.value.v6 ? "IPv6" : "IPv4"
    protocol          = each.value.proto
    port_range_min    = each.value.port
    port_range_max    = each.value.port
    remote_ip_prefix  = each.value.cidr
    security_group_id = openstack_networking_secgroup_v2.sandbox_egress.id
  }
  ```
  Manual CLI test before Terraform:
  ```bash
  openstack network security group create sbx
  openstack network security group rule create --egress --protocol udp \
      --port-range-min 53 --port-range-max 53 --remote-ip <resolver>/32 sbx
  # ... repeat per slot; then boot/attach ONLY sbx:
  openstack server add security group <vm> sbx
  openstack server remove security group <vm> default
  ```

- **FWaaS**: ask NREC ops whether **Cloud-Native Firewall (FWaaS v3, Antelope+)**
  is available — its *policy-based* filtering supports **FQDN address filters**
  (auto DNS resolution, like the dnsmasq→nft-set trick) and logging. If yes,
  domain-granular sandbox without an extra VM becomes possible. Classic FWaaS
  v2 object-groups are static — no better than SGs.
- **Full-parity option** (mirror of the KVM design): private Neutron net with
  no route for the agent VM + a shield/router instance (two ports; floating IP
  on shield only; nft/dnsmasq as in `cloud-init-shield.yaml.tftpl`). Costs one
  small flavor; buys DNS logs, legible rejects, L2 isolation. This is the
  upgrade path when SG granularity is not enough.

## Endpoint → CIDR slots (verified 2026-11-09 — regenerate before pinning)

CDN-backed endpoints rotate; re-run resolution at implementation time, and
prefer gateways (U4) over pinning.

- **gpt.uio.no** → `129.240.118.29/32` (v4), `2001:700:100:8040::29/128` (v6) —
  UiO 129.240/16 space; single-host pin is stable, ask UiO IT for the canonical
  range.
- **OpenAI/Anthropic/etc.** → behind Cloudflare; live list:
  `https://api.cloudflare.com/client/v4/ips` (v4: 15 CIDRs incl. 104.16.0.0/13,
  172.64.0.0/13, 162.158.0.0/15 …; v6: 2606:4700::/32, 2a06:98c0::/29 …).
  ⚠ allow-listing these ≈ allow-listing all of Cloudflare (any webhook host) —
  sandbox profile should NOT include them; route via gpt.uio.no.
- **Ubuntu mirrors (archive/security/ntp.ubuntu.com)** → Canonical CDN
  (resolved 185.125.190.x, 91.189.91.x; v6 2620:2d:4000:1::x — Canonical AS41238
  announced set, commonly 185.125.128.0/19 + 91.189.88.0/22 + 2620:2d:4000::/40;
  verify with `whois`/RDAP at pin time).
- **GitHub (toolchain downloads)** → authoritative JSON:
  `https://api.github.com/meta` (`git`, `api`, `web` keys). Observed:
  github.com = 140.82.112.0/20, objects.githubusercontent.com = 185.199.108.0/22.
- **Google (Chrome, dl.google.com)** → AS15169 announced prefixes:
  `https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS15169`
  (large set — consider fetching Chrome .deb once at build time instead of
  allowing all of Google in `ubuntu`).

Regenerate resolver data with:
```bash
python3 - <<'EOF'
import socket
for n in ['gpt.uio.no','archive.ubuntu.com','security.ubuntu.com','ntp.ubuntu.com',
          'github.com','objects.githubusercontent.com','dl.google.com']:
    for r in socket.getaddrinfo(n, None):
        print(n, r[0].name, r[4][0])
EOF
```

## What security groups alone cannot do (vs the KVM shield)

- no domain→IP mirroring / FQDN allow-lists (unless FWaaS v3 CNFW at NREC);
- no DNS query log, no counters, no flow visibility (monitoring must then move
  to the agent VM — tamperable — or to a shield/router VM for tamper-evidence);
- silent drops only (no legible reject → U9 mitigation: deliver the profile
  text to the agent);
- no L7/URL policies (needs the proxy layer on a gateway regardless).

Decision guide for the port: start with the SG-only sandbox (U0–U6 as CIDR
pins; coarse but hypervisor-enforced and zero extra VMs), graduate to the
shield/router VM when you want the DNS layer, logs, and legible denies in
OpenStack too — the KVM shield template ports almost 1:1.
