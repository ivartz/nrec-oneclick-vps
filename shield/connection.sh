# Shared operator connection for local KVM and NREC shields. ID is set by caller.
if [[ "$ID" == vps-local-* ]]; then
    HEX=${ID#vps-local-}
    GW="10.99.$(( 16#${HEX: -2} % 239 + 1 )).2"
    SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i keys/$ID.pem ubuntu@$GW"
else
    [ -f "vm/$ID.outputs.json" ] || { echo "Missing vm/$ID.outputs.json" >&2; exit 1; }
    GW=$(python3 - "vm/$ID.outputs.json" "$ID" <<'PY'
import json,sys,ipaddress
s=json.load(open(sys.argv[1]))
assert s['deployment_id']['value']==sys.argv[2], 'Metadata deployment mismatch'
print(ipaddress.IPv4Address(s['shield_ipv4']['value']))
PY
)
    SSH="ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -i keys/$ID.pem ubuntu@$GW"
fi
