#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ID=${1:?usage: shield-setup-openstack.sh deployment-id}
STATE=${STATE:-terraform.tfstate}
VARS=${VARS:-vm/openstack.tfvars.json}
SHIELD=${SHIELD:-ubuntu}
source env.sh
source termux_fix.sh
out() { terraform output -state="$STATE" -raw "$1"; }
[ "$(out deployment_id)" = "$ID" ] || { echo 'Deployment/state mismatch'; exit 1; }
AGENT=$(out agent_ipv4); GATEWAY=$(out shield_ipv4)
KEY=$(out private_key_path)
# NREC recycles public IPs between deployments, so a pinned known_hosts entry
# from a destroyed VM silently rejects the new occupant (accept-new refuses
# CONFLICTING keys). Host identity here is the per-deployment keypair, not the
# IP: trust-on-first-use is meaningless across recycling. LogLevel=ERROR keeps
# the "Permanently added" note from printing on every connection.
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -i "$KEY")
SCP=(scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$KEY")
# Fail closed on setup failure, rather than leave bootstrap internet access.
lock_agent() {
    python3 - "$VARS" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); v=json.loads(p.read_text()); v['sandbox_bootstrap']=False;p.write_text(json.dumps(v,indent=2)+'\n')
PY
    terraform plan -input=false -state="$STATE" -var-file="$VARS" -out=vm/lock.plan > vm/lock-plan.log
    terraform show -json vm/lock.plan > vm/lock-plan.json
    python3 - <<'PY'
import json
p=json.load(open('vm/lock-plan.json'))
for r in p.get('resource_changes',[]):
    if r['change']['actions'] != ['no-op']:
        assert r['address']=='openstack_networking_secgroup_rule_v2.agent_bootstrap[0]' and r['change']['actions']==['delete'],r
PY
    terraform apply -input=false -state="$STATE" vm/lock.plan > vm/lock-apply.log
}
trap 'rc=$?; if [ "$rc" != 0 ]; then lock_agent || echo "ERROR: automatic lockdown failed; inspect vm/lock-plan.log" >&2; fi; exit "$rc"' EXIT
for HOST in "$AGENT" "$GATEWAY"; do
    "${SCP[@]}" shield/bootstrap-wireguard.sh "ubuntu@$HOST:bootstrap-wireguard.sh"
    "${SSH[@]}" "ubuntu@$HOST" 'sudo bash /home/ubuntu/bootstrap-wireguard.sh'
done
APUB=$("${SSH[@]}" "ubuntu@$AGENT" 'sudo cat /etc/wireguard/private.key | wg pubkey')
SPUB=$("${SSH[@]}" "ubuntu@$GATEWAY" 'sudo cat /etc/wireguard/private.key | wg pubkey')
OPERATOR=$(python3 - "$VARS" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['operator_public_ipv4'])
PY
)
"${SCP[@]}" shield/setup-openstack.py shield/prepare-openstack.sh "ubuntu@$GATEWAY:"
"${SCP[@]}" "shield/profile-$SHIELD.txt" "ubuntu@$GATEWAY:profile.txt"
"${SSH[@]}" "ubuntu@$GATEWAY" "sudo bash /home/ubuntu/prepare-openstack.sh '$APUB' '$AGENT' '$OPERATOR'"
"${SCP[@]}" shield/setup-agent.sh "ubuntu@$AGENT:setup-agent.sh"
"${SSH[@]}" "ubuntu@$AGENT" "sudo bash /home/ubuntu/setup-agent.sh '$GATEWAY' '$SPUB'"
lock_agent
trap - EXIT
"${SSH[@]}" "ubuntu@$GATEWAY" 'sudo wg show; sudo nft list ruleset; systemctl is-active dnsmasq nftables wg-quick@wg0 shield-keepalive.timer'
if [ "$SHIELD" = ubuntu ]; then
    "${SCP[@]}" shield/verify-agent.sh "ubuntu@$AGENT:verify-agent.sh"
    "${SSH[@]}" "ubuntu@$AGENT" 'sudo bash /home/ubuntu/verify-agent.sh'
else
    "${SSH[@]}" "ubuntu@$AGENT" 'sudo wg show; resolvectl status wg0'
    echo 'Custom profile installed; run its own allowed/denied traffic checks.'
fi
printf 'Agent=%s shield=%s profile=%s; bootstrap egress removed.\n' "$AGENT" "$GATEWAY" "$SHIELD"
