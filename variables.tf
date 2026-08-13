variable "insecure" {
  type    = bool
  default = false
}

variable "deployment_id" {
  type    = string
  default = ""
}

variable "keys_dir" {
  type    = string
  default = "keys"
}

variable "flavor_name" {
  type    = string
  default = "c1.xlarge"
}

variable "image_name" {
  type    = string
  default = "GOLD Ubuntu 24.04 LTS"
}

variable "availability_zone" {
  type    = string
  default = ""
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "admin_user" {
  type    = string
  default = "ubuntu"
}

variable "turbovnc_deb_url" {
  type    = string
  default = "https://github.com/TurboVNC/turbovnc/releases/download/3.3/turbovnc_3.3_amd64.deb"
}

variable "local_vnc_port" {
  type    = number
  default = 55901
}

variable "operator_public_ipv4" {
  type    = string
  default = ""
}

variable "operator_public_ipv6" {
  type    = string
  default = ""
}
