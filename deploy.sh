#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source env.sh

OPERATOR_IPv4=$(curl -4 -s --max-time 5 ifconfig.co 2>/dev/null || echo "")
[ -n "$OPERATOR_IPv4" ] && echo "Public IPv4: $OPERATOR_IPv4" || echo "Could not detect public IPv4"

OPERATOR_IPv6=$(curl -6 -s --max-time 5 ifconfig.co 2>/dev/null || echo "")
[ -n "$OPERATOR_IPv6" ] && echo "Public IPv6: $OPERATOR_IPv6" || echo "Could not detect public IPv6"

DEPLOYMENT_ID="hermes-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 6)"

INSECURE=false
[ -d /data/data/com.termux ] && INSECURE=true

cat > terraform.tfvars << EOF
flavor_name          = "c1.xlarge"
image_name           = "GOLD Ubuntu 24.04 LTS"
admin_user           = "hermes"
ssh_user             = "ubuntu"
local_vnc_port       = 55901
local_ollama_port    = 51434
operator_public_ipv4   = "${OPERATOR_IPv4}"
operator_public_ipv6 = "${OPERATOR_IPv6}"
deployment_id        = "${DEPLOYMENT_ID}"
insecure             = ${INSECURE}
EOF

echo "Deploying ${DEPLOYMENT_ID}..."

# Termux DNS workaround
if [ -d /data/data/com.termux ]; then
    source termux_fix.sh
fi

terraform init -input=false
terraform plan -input=false
terraform apply -auto-approve -input=false

echo ""
echo "VM IPv4: $(terraform output -raw vm_ipv4)"
echo "VM IPv6: $(terraform output -raw vm_ipv6)"
echo "SSH private Key:   $(terraform output -raw private_key_path)"
echo "Admin/VNC Pass:  $(terraform output -raw admin_password)"

echo ""
echo "Connect over SSH with:"
terraform output -raw vnc_tunnel_command
echo ""
