# One underlay interface per VM. WireGuard supplies the isolated agent network.
variable "shield_flavor_name" {
  type    = string
  default = "c1.medium"
}
variable "sandbox_bootstrap" {
  type    = bool
  default = true
}

data "openstack_compute_flavor_v2" "shield" {
  name = var.shield_flavor_name
}
resource "openstack_networking_secgroup_v2" "shield" {
  name        = "${local.deployment_id}-shield"
  description = "Shield: operator SSH and agent WireGuard only"
}
resource "openstack_networking_secgroup_rule_v2" "shield_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = local.operator_ipv4_cidr
  security_group_id = openstack_networking_secgroup_v2.shield.id
}
resource "openstack_networking_secgroup_rule_v2" "shield_wireguard" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 51820
  port_range_max    = 51820
  remote_ip_prefix  = "${openstack_compute_instance_v2.agent.access_ip_v4}/32"
  security_group_id = openstack_networking_secgroup_v2.shield.id
}
# Shield deliberately retains Neutron's unrestricted default egress.
resource "null_resource" "agent_default_egress" {
  triggers = { group_id = openstack_networking_secgroup_v2.agent.id }
  provisioner "local-exec" {
    command = "python3 shield/remove-default-egress.py '${local.deployment_id}-agent' '${openstack_networking_secgroup_v2.agent.id}'"
  }
}
resource "openstack_networking_secgroup_rule_v2" "agent_bootstrap" {
  depends_on        = [null_resource.agent_default_egress]
  count             = var.sandbox_bootstrap ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.agent.id
}
resource "openstack_networking_secgroup_rule_v2" "agent_wireguard" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 51820
  port_range_max    = 51820
  remote_ip_prefix  = "${openstack_compute_instance_v2.shield.access_ip_v4}/32"
  security_group_id = openstack_networking_secgroup_v2.agent.id
}
resource "openstack_compute_instance_v2" "shield" {
  name              = "${local.deployment_id}-shield"
  flavor_id         = data.openstack_compute_flavor_v2.shield.id
  image_id          = data.openstack_images_image_v2.ubuntu.id
  availability_zone = var.availability_zone
  key_pair          = openstack_compute_keypair_v2.deployer.name
  security_groups   = [openstack_networking_secgroup_v2.shield.name]
  network { uuid = local.network_id }
  user_data = <<-YAML
    #cloud-config
    package_update: true
    packages: [wireguard, dnsmasq, nftables, conntrack, dnsutils]
    runcmd:
      - [systemctl, disable, --now, dnsmasq]
  YAML
}
output "shield_ipv4" { value = openstack_compute_instance_v2.shield.access_ip_v4 }
output "shield_ipv6" { value = openstack_compute_instance_v2.shield.access_ip_v6 }
output "agent_security_group_id" { value = openstack_networking_secgroup_v2.agent.id }
output "shield_security_group_id" { value = openstack_networking_secgroup_v2.shield.id }
