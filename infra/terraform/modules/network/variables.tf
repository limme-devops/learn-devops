# Author: Mengty LIM
variable "environment" {
  description = "Environment name; prefixes every resource and drives policy strictness."
  type        = string

  validation {
    condition     = contains(["dev", "sit", "uat", "prod", "dr"], var.environment)
    error_message = "environment must be one of: dev, sit, uat, prod, dr."
  }
}

variable "supernet" {
  description = "The /16 (or larger) this environment carves its zone subnets from."
  type        = string

  validation {
    condition     = can(cidrhost(var.supernet, 0)) && tonumber(split("/", var.supernet)[1]) <= 20
    error_message = "supernet must be a valid CIDR of /20 or larger to fit four zone subnets."
  }
}

variable "vlan_base" {
  description = "Base VLAN id; zones are allocated at base+10, +20, +30, +40."
  type        = number

  validation {
    condition     = var.vlan_base >= 100 && var.vlan_base <= 4000
    error_message = "vlan_base must be between 100 and 4000."
  }
}

variable "dvs_uuid" {
  description = "UUID of the distributed virtual switch to attach port groups to."
  type        = string
}

variable "firewall_section_id" {
  description = "Firewall policy section that owns this environment's rules."
  type        = string
}

variable "bastion_cidr" {
  description = "CIDR of the bastion/PAM hosts permitted to open SSH sessions."
  type        = string
}

variable "forward_proxy_cidr" {
  description = "CIDR of the outbound forward proxy. Direct egress is never permitted."
  type        = string
}

variable "extra_allow_rules" {
  description = <<-EOT
    Additional allow rules. Every entry MUST carry a `reason` — an unexplained
    firewall exception will be rejected at review and flagged at audit.
  EOT
  type = list(object({
    name        = string
    source      = string
    destination = string
    ports       = list(string)
    protocol    = string
    reason      = string
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.extra_allow_rules : length(r.reason) >= 15])
    error_message = "Each extra_allow_rules entry needs a reason of at least 15 characters."
  }
}

variable "tags" {
  description = "Tags applied to every resource. owner/cost-center/data-class are mandatory."
  type        = map(string)

  validation {
    condition = alltrue([
      for k in ["owner", "cost-center", "data-class"] : contains(keys(var.tags), k)
    ])
    error_message = "tags must include owner, cost-center and data-class."
  }
}
