#!/usr/bin/env python3
"""Remove Neutron implicit allow-all rules ONLY from this state's agent SG."""
import json, os, subprocess, sys
name, group = sys.argv[1:]
env = {k:v for k,v in os.environ.items() if k.lower() not in ('http_proxy','https_proxy','all_proxy')}
def cli(*args):
    return subprocess.check_output(['openstack', *args], env=env, text=True)
actual = json.loads(cli('security','group','show',group,'-f','json'))
if actual['name'] != name or not name.startswith('vps-') or not name.endswith('-agent'):
    sys.exit('Refusing: SG name does not match this deployment agent group')
rules = json.loads(cli('security', 'group', 'rule', 'list', group, '-f', 'json'))
for row in rules:
    rid = row['ID']
    r = json.loads(cli('security','group','rule','show',rid,'-f','json'))
    if r['direction'] == 'egress' and r.get('remote_ip_prefix') in (None, '', '0.0.0.0/0', '::/0') and not any(r.get(k) for k in ('protocol','remote_group_id','port_range_min','port_range_max')):
        subprocess.run(['openstack','security','group','rule','delete',rid],env=env,check=True)
remaining = json.loads(cli('security','group','rule','list',group,'-f','json'))
print('Agent SG after implicit-rule cleanup:', json.dumps(remaining))
