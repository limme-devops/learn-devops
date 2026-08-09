# Author: Mengty LIM
variable "environment" {
  type        = string
  description = "Environment name."
  validation {
    condition     = contains(["dev", "sit", "uat", "prod", "dr"], var.environment)
    error_message = "environment must be one of: dev, sit, uat, prod, dr."
  }
}

variable "role" {
  type        = string
  description = "Functional role of this pool (app, web, db, lb, bastion, k8s-worker...)."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.role))
    error_message = "role must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}

variable "instance_count" {
  type        = number
  description = "Number of VMs in the pool."
  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 50
    error_message = "instance_count must be between 1 and 50."
  }
}

variable "cpu" {
  type        = number
  description = "vCPUs per VM."
  default     = 2
}

variable "memory_mb" {
  type        = number
  description = "RAM per VM in MB."
  default     = 4096
}

variable "root_disk_gb" {
  type        = number
  description = "Root disk size in GB."
  default     = 60
}

variable "data_disk_gb" {
  type        = number
  description = "Separate encrypted data disk in GB. 0 disables it."
  default     = 0
}

variable "guest_id" {
  type        = string
  description = "vSphere guest OS identifier."
  default     = "rhel9_64Guest"
}

variable "golden_image_uuid" {
  type        = string
  description = "UUID of the Packer-built, CIS-hardened template to clone."
}

variable "resource_pool_id" {
  type        = string
  description = "Target resource pool."
}

variable "datastore_id" {
  type        = string
  description = "Target datastore. Must be an encrypted datastore for data-class=restricted."
}

variable "port_group_id" {
  type        = string
  description = "Port group from the network module's zone_networks output."
}

variable "subnet_cidr" {
  type        = string
  description = "Subnet the pool takes addresses from."
}

variable "ip_offset" {
  type        = number
  description = "Host offset within subnet_cidr for the first VM. Keep pools non-overlapping."
  default     = 20
}

variable "gateway_ip" {
  type        = string
  description = "Default gateway for the subnet."
}

variable "dns_servers" {
  type        = list(string)
  description = "Internal DNS resolvers."
}

variable "dns_domain" {
  type        = string
  description = "DNS domain for A records."
}

variable "placement_zones" {
  type        = list(string)
  description = "Failure domains (racks/hosts/clusters) to spread instances across."
  default     = ["rack-a", "rack-b", "rack-c"]

  validation {
    condition     = length(var.placement_zones) >= 1
    error_message = "At least one placement zone is required."
  }
}

variable "bootstrap_ssh_public_key" {
  type        = string
  description = "Short-lived bootstrap public key. Rotated out by the baseline Ansible role."
  sensitive   = true
}

variable "take_pre_change_snapshot" {
  type        = bool
  description = "Snapshot before changes. Convenience only — snapshots are not backups."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every VM. owner/cost-center/data-class are mandatory."

  validation {
    condition = alltrue([
      for k in ["owner", "cost-center", "data-class"] : contains(keys(var.tags), k)
    ])
    error_message = "tags must include owner, cost-center and data-class."
  }
}
