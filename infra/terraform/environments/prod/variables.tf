variable "vsphere_server" { type = string }
variable "vsphere_datacenter" { type = string }
variable "vsphere_cluster" { type = string }

variable "datastore_bulk" {
  type        = string
  description = "General-purpose datastore."
}

variable "datastore_fast" {
  type        = string
  description = "Low-latency (NVMe) datastore for etcd and database volumes."
}

variable "golden_image_name" {
  type        = string
  description = "Packer-built CIS-hardened template name, including its build date."
}

variable "supernet" {
  type        = string
  description = "Environment supernet; zones are carved from it."
}

variable "vlan_base" { type = number }
variable "dvs_uuid" { type = string }
variable "firewall_section_id" { type = string }
variable "bastion_cidr" { type = string }
variable "forward_proxy_cidr" { type = string }

variable "apiserver_vip" { type = string }
variable "ingress_vip" { type = string }

variable "dns_servers" { type = list(string) }
variable "dns_domain" { type = string }
variable "dns_update_server" { type = string }
variable "haproxy_dataplane_url" { type = string }

variable "placement_zones" {
  type        = list(string)
  description = "Physical failure domains to spread across."
}
