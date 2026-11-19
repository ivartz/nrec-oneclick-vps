#!/bin/bash
set -euo pipefail
cd /home/ubuntu
python3 - "$1" "$2" "$3" <<'PY'
import json,sys,os
from pathlib import Path
os.umask(0o077)
Path('/etc/wireguard/setup.json').write_text(json.dumps(dict(shield_private_key=Path('/etc/wireguard/private.key').read_text().strip(),agent_public_key=sys.argv[1],agent_ipv4=sys.argv[2],operator_ipv4=sys.argv[3])))
PY
python3 setup-openstack.py /etc/wireguard/setup.json profile.txt
rm /etc/wireguard/setup.json
