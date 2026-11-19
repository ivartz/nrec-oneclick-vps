# Sandbox technical notes

## Networking and limits

The agent and shield are separate VMs. The diagrams show the normal shielded setup after provisioning.

### NREC OpenStack

```text
 Operator -- SSH --> agent and shield (NREC network addresses)

 +------------------+      NREC IPv4 network      +---------------------+
 | Agent VM         |                             | Shield VM           |
 | vps-<id>-agent   |== WireGuard, UDP 51820 ===>| vps-<id>-shield     |
 | wg0: 10.99.0.10  |   DNS + IPv4 traffic       | wg0: 10.99.0.2      |
 +------------------+                             | dnsmasq + nftables  |
         |                                        | IPv4 masquerade     |
         | agent security group:                  +----------+----------+
         | outbound UDP 51820 to shield only                 |
         | direct IPv4/IPv6 egress blocked                   v
         X                                              NREC network
     direct internet                                         |
                                                             v
                                                          Internet
```

The agent security group permits the tunnel after bootstrap; it also allows operator SSH ingress and stateful replies. The shield filters forwarded traffic and resolves DNS for the agent.

### Local KVM

```text
 KVM host -- SSH --> agent and shield via agentbox-N

 +------------------------+    isolated libvirt network    +------------------------+
 | Agent VM               |          agentbox-N            | Shield VM              |
 | vps-local-<id>-agent   |                                | vps-local-<id>-shield  |
 | 10.99.N.10             |<------------------------------>| 10.99.N.2 (lan0)       |
 | gateway/DNS: 10.99.N.2 |              |                 | dnsmasq + nftables     |
 +------------------------+              |                 | NAT; wan0              |
                              host bridge: 10.99.N.1       +-----------+------------+
                                                                       |
                                                          libvirt default network
                                                                       |
                                                                KVM host NAT
                                                                       |
                                                                   Internet
```

`N` is derived from the deployment ID. The agent's isolated network has no DHCP or direct internet forwarding; the shield is its gateway. The host bridge provides operator access to both VMs.

This is IP-based filtering, not URL or content filtering. DNS queries for unlisted domains can still resolve, and a destination sharing an allowed IP may be reachable. Direct IPv6 egress from the NREC agent is blocked; use `curl -4` when testing an IPv4 allow or denial. NREC's `IPv6` network and private-IPv4 WireGuard transport have not been live-tested in this setup.

NREC bootstrap temporarily permits agent IPv4 egress for package installation. Setup removes this rule and attempts to remove it on failure. `./deploy.sh --provision-only` deliberately leaves bootstrap open; finish with `SHIELD=<profile> ./shield-setup-openstack.sh <deployment-id>`.

## Profiles and reports

Profiles are domain lists at `shield/profile-<name>.txt`. `shield-allow.sh` updates the selected local profile and the live shield; it attempts to add a detected CNAME target too. Check the output and add any additional targets needed by a CNAME chain. Reapplying uses the profile file next to the script as the source of truth: keep profile edits in sync if you operate from separate repository copies.

`shield-suggest.sh` correlates logged blocked IPv4 destinations with DNS queries and may provide reverse-DNS hints. It does not change the policy; hints are not proof a domain is safe. On the shield, `sudo shield-report` shows a network audit.

## State and access

NREC defaults to `terraform.tfstate` and `vm/openstack.tfvars.json`; `STATE` and `VARS` override them for deployment and setup. Use distinct state and variable files for separate deployments. Keep `vm/<deployment-id>.outputs.json` and `keys/<deployment-id>.pem`: shield commands use them to connect.

Local deployment prints agent and shield addresses, and stores the generated Ubuntu password in `keys/<deployment-id>.password`. NREC stores the generated VNC password in `keys/<deployment-id>.vncpass`. Treat generated keys, passwords, Terraform state and variable files as sensitive.

NREC public IPs can be reused. If SSH reports a changed host key, verify the new host's identity independently before updating your known-hosts entry. Disabling SSH host-key checking removes server authentication; the client private key alone does not authenticate the server.

## Troubleshooting

- On a newly booting NREC shield, dnsmasq can fail during package installation before shield setup configures it. Check its final status after setup with `systemctl status dnsmasq`; a completed setup should have it active.
- For an unexpected deny, run `./shield-suggest.sh <deployment-id> --since '20 s ago'` and inspect `sudo shield-report` on the shield. Try a fresh `curl -4` from the agent.
- If setup fails, inspect its output and the bootstrap rule before retrying. The failure handler attempts to remove bootstrap egress; a retry may require restoring that rule temporarily. Do not use a fresh deploy against an existing state.
- TurboVNC may not be in the PATH of a non-interactive SSH command. Use `/opt/TurboVNC/bin/vncserver` in that case.
