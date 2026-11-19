#!/bin/bash
# Fresh pair only: never replace resources already owned by the selected state.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source env.sh
SHIELD=${SHIELD:-ubuntu}
[[ "$SHIELD" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1
[ -f "shield/profile-$SHIELD.txt" ] || { echo "Missing profile $SHIELD"; exit 1; }
source shield/validation.sh
profile_domains "shield/profile-$SHIELD.txt" >/dev/null
STATE=${STATE:-terraform.tfstate}
VARS=${VARS:-vm/openstack.tfvars.json}
mkdir -p vm keys
ID=${DEPLOYMENT_ID:-$(python3 -c 'import secrets; print("vps-"+secrets.token_hex(3))')}
if [ -f "$STATE" ]; then
    python3 - "$STATE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
if any(r.get('mode','managed')=='managed' for r in s.get('resources',[])):
    sys.exit('State owns resources: select a fresh STATE; refusing replacement.')
PY
fi
OPERATOR_IPv4=$(curl -4 -fsS --max-time 20 https://api.ipify.org)
OPERATOR_IPv6=${OPERATOR_PUBLIC_IPV6:-}
export ID OPERATOR_IPv4 OPERATOR_IPv6
python3 - "$VARS" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True)
p.write_text(json.dumps(dict(deployment_id=os.environ['ID'],operator_public_ipv4=os.environ['OPERATOR_IPv4'],operator_public_ipv6=os.environ['OPERATOR_IPv6'],flavor_name='c1.xlarge',shield_flavor_name='c1.medium',image_name='GOLD Ubuntu 24.04 LTS',admin_user='ubuntu',ssh_user='ubuntu',local_vnc_port=55901,insecure=Path('/data/data/com.termux').exists(),sandbox_bootstrap=True),indent=2)+'\n')
PY
source termux_fix.sh
terraform init -input=false
terraform validate
terraform plan -input=false -state="$STATE" -var-file="$VARS" -out=vm/provision.plan
terraform apply -input=false -state="$STATE" vm/provision.plan
terraform output -state="$STATE" -json > "vm/$ID.outputs.json"
printf 'Created %s; state=%s vars=%s\n' "$ID" "$STATE" "$VARS"
if [ "${1:-}" = --provision-only ]; then
    echo 'Bootstrap IPv4 egress open; finish with shield-setup-openstack.sh.'
else
    STATE="$STATE" VARS="$VARS" SHIELD="$SHIELD" ./shield-setup-openstack.sh "$ID"
fi
