variable "environment" {
  type        = string
  description = "Environment name."
  validation {
    condition     = contains(["dev", "sit", "uat", "prod", "dr"], var.environment)
    error_message = "environment must be one of: dev, sit, uat, prod, dr."
  }
}

variable "cluster_suffix" {
  type        = string
  description = "Short cluster identifier, e.g. 'k8s' or 'k8s-payments'."
  default     = "k8s"
}

variable "control_plane_count" {
  type        = number
  description = "Control-plane nodes. Must be odd for etcd quorum."
  default     = 3

  validation {
    condition     = var.control_plane_count % 2 == 1 && var.control_plane_count >= 1
    error_message = "control_plane_count must be an odd number (1, 3 or 5) for etcd quorum."
  }
}

variable "control_plane_cpu" {
  type    = number
  default = 4
}

variable "control_plane_memory_mb" {
  type    = number
  default = 8192
}

variable "worker_pools" {
  description = <<-EOT
    Worker node pools keyed by name. Separate pools let you isolate workload
    classes (general vs data vs ingress) onto different hardware and taint them
    accordingly in the Ansible install step.
  EOT
  type = map(object({
    count      = number
    cpu        = number
    memory_mb  = number
    storage_gb = number
    ip_offset  = number
  }))

  default = {
    general = { count = 3, cpu = 8, memory_mb = 32768, storage_gb = 200, ip_offset = 40 }
  }

  validation {
    condition     = length(distinct([for p in values(var.worker_pools) : p.ip_offset])) == length(var.worker_pools)
    error_message = "Each worker pool needs a unique ip_offset, otherwise addresses collide."
  }
}

variable "apiserver_vip" {
  type        = string
  description = "Virtual IP for the kube-apiserver load balancer."
}

variable "ingress_vip" {
  type        = string
  description = "Virtual IP handed to MetalLB / the ingress controller."
}

variable "golden_image_uuid" { type = string }
variable "resource_pool_id" { type = string }
variable "datastore_id" { type = string }

variable "etcd_datastore_id" {
  type        = string
  description = "Low-latency datastore for control-plane/etcd disks. etcd punishes slow fsync."
}

variable "app_zone_port_group_id" { type = string }
variable "app_zone_cidr" { type = string }
variable "gateway_ip" { type = string }
variable "dns_servers" { type = list(string) }
variable "dns_domain" { type = string }

variable "placement_zones" {
  type    = list(string)
  default = ["rack-a", "rack-b", "rack-c"]
}

variable "bootstrap_ssh_public_key" {
  type      = string
  sensitive = true
}

variable "tags" {
  type = map(string)
  validation {
    condition = alltrue([
      for k in ["owner", "cost-center", "data-class"] : contains(keys(var.tags), k)
    ])
    error_message = "tags must include owner, cost-center and data-class."
  }
}
