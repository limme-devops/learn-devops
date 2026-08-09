# Author: Mengty LIM
output "instances" {
  description = "Map of hostname => { ip, uuid, zone }."
  value = {
    for name, inst in local.instances : name => {
      ip   = inst.ip
      uuid = vsphere_virtual_machine.this[name].uuid
      zone = inst.zone
    }
  }
}

output "ip_addresses" {
  description = "Flat list of IPs, ordered by instance index."
  value       = [for name, inst in local.instances : inst.ip]
}

output "fqdns" {
  description = "Fully-qualified names for use in load balancer and monitoring config."
  value       = [for name, _ in local.instances : "${name}.${var.dns_domain}"]
}

output "ansible_inventory_group" {
  description = <<-EOT
    Inventory fragment for Ansible. The pipeline writes this to
    infra/ansible/inventories/<env>/generated/<role>.yml so that Ansible never
    guesses which hosts exist — Terraform is the source of truth.
  EOT
  value = {
    (replace(var.role, "-", "_")) = {
      hosts = {
        for name, inst in local.instances : "${name}.${var.dns_domain}" => {
          ansible_host = inst.ip
          vm_zone      = inst.zone
          vm_role      = var.role
        }
      }
    }
  }
}
