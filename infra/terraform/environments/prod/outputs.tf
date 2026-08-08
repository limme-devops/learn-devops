output "k8s_apiserver_endpoint" {
  description = "Cluster API endpoint for kubeconfig generation."
  value       = module.k8s.apiserver_endpoint
}

# The pipeline writes this to inventories/prod/generated/ so Ansible always
# targets exactly what Terraform built — no hand-maintained host lists.
output "ansible_inventory" {
  description = "Generated Ansible inventory for every host in this environment."
  value = merge(
    module.k8s.ansible_inventory,
    module.loadbalancer_vms.ansible_inventory_group,
    module.app_vms.ansible_inventory_group,
    module.db_vms.ansible_inventory_group,
  )
}

output "network_zones" {
  description = "Zone CIDRs — consumed by NetworkPolicy generation and firewall audits."
  value       = module.network.zone_networks
}

output "firewall_allow_rule_count" {
  description = "Watch this number. Sudden growth means someone is punching holes."
  value       = module.network.allow_rule_count
}
