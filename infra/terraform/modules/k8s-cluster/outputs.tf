# Author: Mengty LIM
output "cluster_name" {
  value = local.cluster_name
}

output "apiserver_endpoint" {
  description = "URL Ansible and kubeconfigs should point at. Never a single node IP."
  value       = "https://${local.cluster_name}-api.${var.dns_domain}:6443"
}

output "control_plane_nodes" {
  value = module.control_plane.instances
}

output "worker_nodes" {
  value = { for pool, m in module.worker : pool => m.instances }
}

output "ansible_inventory" {
  description = <<-EOT
    Complete inventory for playbooks/k8s-install.yml. Written to
    inventories/<env>/generated/k8s.yml by the pipeline. The first control-plane
    node is marked as the bootstrap ("init") node — RKE2 needs exactly one.
  EOT
  value = {
    k8s_control_plane = {
      hosts = {
        for name, inst in module.control_plane.instances :
        "${name}.${var.dns_domain}" => {
          ansible_host   = inst.ip
          vm_zone        = inst.zone
          rke2_bootstrap = name == keys(module.control_plane.instances)[0]
        }
      }
    }
    k8s_workers = {
      children = {
        for pool, m in module.worker : "k8s_workers_${replace(pool, "-", "_")}" => {
          hosts = {
            for name, inst in m.instances :
            "${name}.${var.dns_domain}" => {
              ansible_host = inst.ip
              vm_zone      = inst.zone
              node_pool    = pool
            }
          }
        }
      }
    }
  }
}
