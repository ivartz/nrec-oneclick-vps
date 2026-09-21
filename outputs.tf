output "deployment_id" {
  value = local.deployment_id
}

output "vm_ipv4" {
  value = openstack_compute_instance_v2.vm.access_ip_v4
}

output "vm_ipv6" {
  value = openstack_compute_instance_v2.vm.access_ip_v6
}

output "admin_user" {
  value = var.admin_user
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "private_key_path" {
  value = local.private_key
}

output "password_file_path" {
  value = local.password_file
}

output "ssh_command" {
  value = local.has_ipv6 ? "ssh -i ${local.private_key} ${var.ssh_user}@${openstack_compute_instance_v2.vm.access_ip_v6} -X" : "ssh -i ${local.private_key} ${var.ssh_user}@${openstack_compute_instance_v2.vm.access_ip_v4}"
}

output "ssh_and_rdp_tunnel_command" {
  value = local.has_ipv6 ? "ssh -L ${var.local_rdp_port}:localhost:3389 -i ${local.private_key} ${var.ssh_user}@${openstack_compute_instance_v2.vm.access_ip_v6}" : "ssh -L ${var.local_rdp_port}:localhost:3389 -i ${local.private_key} ${var.ssh_user}@${openstack_compute_instance_v2.vm.access_ip_v4}"
}

output "rdp_connect_command" {
  value = "rdpclient --port ${var.local_rdp_port} localhost"
}
