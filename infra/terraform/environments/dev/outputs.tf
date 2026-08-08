output "k8s_apiserver_endpoint" {
  value = module.k8s.apiserver_endpoint
}

output "ansible_inventory" {
  value = merge(
    module.k8s.ansible_inventory,
    module.app_vms.ansible_inventory_group,
  )
}

output "network_zones" {
  value = module.network.zone_networks
}
