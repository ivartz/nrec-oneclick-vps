# Agent sandbox VPS

Deploy an Ubuntu agent VM and a separate network shield on NREC OpenStack or a local KVM host. The agent has a GNOME desktop accessible through TurboVNC.

## Prerequisites

- **NREC:** Terraform 1.5 or later, SSH, and NREC credentials. Copy `env.sh.template` to `env.sh` and fill in your credentials and project.
- **Local KVM:** Ubuntu 24.04 host with KVM enabled, SSH, and:

  ```bash
  sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients cloud-image-utils virtinst wget
  ```

- A VNC client for desktop access.

## Deploy

Run from the repository directory. For local KVM, run on the KVM host.

NREC:

```bash
SHIELD=ubuntu ./deploy.sh
```

Local KVM:

```bash
SHIELD=ubuntu ./deploy-local.sh
```

`ubuntu` is the default if `SHIELD` is unset. Other presets are in `shield/profile-*.txt`; use the filename without `profile-` and `.txt` as the profile name.

Save the deployment ID and addresses printed by the script. The ID identifies the pair, for example `vps-9d9148` on NREC or `vps-local-9d9148` on KVM. VM names add `-agent` and `-shield`. The generated SSH key is `keys/vps-<deployment-id>.pem`.

NREC uses `terraform.tfstate` by default. A new deploy refuses a state that already owns resources. Keep the state, `vm/openstack.tfvars.json`, `vm/<deployment-id>.outputs.json` and the generated key for managing the deployment. See [technical notes](docs/sandbox.md) for separate states and bootstrap details.

## Connect and start the desktop

Use the addresses printed at deployment. For local KVM, run SSH and the shield commands on the KVM host, which can reach the isolated guest network.

```bash
ssh -i keys/<deployment-id>.pem ubuntu@<agent-ip>
ssh -i keys/<deployment-id>.pem ubuntu@<shield-ip>
```

On the agent, set the Ubuntu user password and the VNC password if desired, then start display 1 as the `ubuntu` user:

```bash
sudo passwd ubuntu
vncpasswd
vncserver :1
```

The default desktop is GNOME Flashback with Metacity. To stop display 1, or start it with modern GNOME instead:

```bash
vncserver -kill :1
vncserver :1 -wm gnome
```

From a vnc client machine that can reach the agent, open an SSH tunnel using the generated key:

```bash
ssh -L 55901:localhost:5901 -i keys/<deployment-id>.pem ubuntu@<agent-ip>
```

Connect your VNC client to `localhost:55901`. If accessing local KVM remotely, run this tunnel on the KVM host and forward its port 55901 to your client, or use an SSH jump through the KVM host.

## Manage the shield

Use the pair's deployment ID (`vps-...`), not the VM name. For a local deployment use its `vps-local-...` ID and run these commands on the KVM host. `shield-allow.sh` and `shield-apply.sh` use the `ubuntu` profile when `SHIELD` is unset; `shield-suggest.sh` reads the live shield and does not select a profile.

Suggest domains to open based on traffic blocked in the last 20 seconds:

```bash
./shield-suggest.sh vps-9d9148 --since '20 s ago'
./shield-suggest.sh vps-local-9d9148 --since '20 s ago'
```

Review suggestions before allowing them. Allow a domain and record it in the selected profile:

```bash
SHIELD=ubuntu ./shield-allow.sh vps-9d9148 search.brave.com
```

The command also detects and adds a CNAME target when present. To revoke a domain:

```bash
SHIELD=ubuntu ./shield-allow.sh --revoke vps-9d9148 search.brave.com
```

Re-apply a profile or change to another one:

```bash
SHIELD=feide ./shield-apply.sh vps-9d9148
```

Applying makes the live allowlist match the selected profile file, removing entries not in that file. Use the correct `SHIELD` when allowing or revoking so the intended profile is updated.

## Destroy

NREC — from the deployment directory, using the same state and variables as the deployment. Review the plan before confirming; this destroys the resources in that Terraform state, including the storage volume:

```bash
source env.sh # if OpenStack credentials are not in environment (check with env | grep OS_)
source termux_fix.sh # If run from Termux
terraform destroy -var-file=vm/openstack.tfvars.json
```

If you used a custom `STATE` or `VARS`, pass the matching paths with `-state` and `-var-file`. Terraform also automatically loads any root `terraform.tfvars` file.

Local KVM — on the KVM host, using the pair's ID. This deletes both VMs and their disks:

```bash
./destroy-local.sh vps-local-9d9148
```

For networking limits, profile behavior and troubleshooting, see [technical notes](docs/sandbox.md).
