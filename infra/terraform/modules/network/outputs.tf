output "zone_networks" {
  description = "Map of zone name => { port_group_id, cidr, vlan }. Consumed by compute modules."
  value = {
    for name, z in local.zones : name => {
      port_group_id = vsphere_distributed_port_group.zone[name].id
      cidr          = z.cidr
      vlan          = z.vlan
    }
  }
}

output "app_zone_cidr" {
  description = "CIDR of the application zone."
  value       = local.zones.app.cidr
}

output "data_zone_cidr" {
  description = "CIDR of the data zone."
  value       = local.zones.data.cidr
}

output "allow_rule_count" {
  description = "Number of explicit allow rules. Track this — it should grow slowly and deliberately."
  value       = length(local.allow_rules)
}
