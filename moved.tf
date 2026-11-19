# Preserve live resource IDs while replacing the old single-VM role labels.
moved {
  from = openstack_compute_instance_v2.vm
  to   = openstack_compute_instance_v2.agent
}
moved {
  from = openstack_networking_secgroup_v2.ssh_only
  to   = openstack_networking_secgroup_v2.agent
}
moved {
  from = data.openstack_compute_flavor_v2.vgpu
  to   = data.openstack_compute_flavor_v2.agent
}
