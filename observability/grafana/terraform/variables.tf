# Author: Mengty LIM
variable "grafana_url" {
  description = "Base URL of the Grafana instance this state manages."
  type        = string
  default     = "https://grafana.bank.internal"

  validation {
    condition     = startswith(var.grafana_url, "https://")
    error_message = "Grafana URL must be https — the provisioning token is a bearer credential."
  }
}

variable "environment" {
  description = "Environment this Grafana serves. Drives alert routing severity and mute timings."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "preprod", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, preprod, prod (see docs/14 §1)."
  }
}

variable "oncall_escalation_minutes" {
  description = "Minutes before an unacknowledged P1 escalates to the secondary on-call."
  type        = number
  default     = 5

  validation {
    condition     = var.oncall_escalation_minutes >= 1 && var.oncall_escalation_minutes <= 15
    error_message = "Escalation must be 1-15 minutes. Longer than 15 and the page is decorative."
  }
}

variable "teams" {
  description = <<-EOT
    Teams and the folders they own. Each gets a Grafana team, an Editor grant on
    its own folder, and Viewer everywhere else. Membership is synced from
    Keycloak groups — this map only defines the folder relationship.
  EOT
  type = map(object({
    keycloak_group = string
    folder_uid     = string
  }))

  default = {
    payments = {
      keycloak_group = "/teams/payments"
      folder_uid     = "services"
    }
    platform = {
      keycloak_group = "/teams/platform"
      folder_uid     = "platform"
    }
  }
}
