# Author: Mengty LIM
terraform {
  required_version = ">= 1.6"

  required_providers {
    grafana = {
      source = "grafana/grafana"
      # Pinned to a minor. The provider renames attributes between majors
      # (folder → folder_uid, rule_group schema changes) and an unpinned
      # provider turns a routine apply into an outage of your alert routing.
      version = "~> 3.13"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
  }

  backend "s3" {
    # MinIO, same pattern as infra/terraform/environments/*/backend.tf.
    # State per component, never one giant state file.
    bucket = "tf-state-observability"
    key    = "grafana/prod/terraform.tfstate"
    region = "us-east-1"

    endpoints                   = { s3 = "https://minio.bank.internal" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    # State holds contact point definitions. Encrypt it, lock it, and give the
    # bucket the same treatment as any other secret-adjacent store.
    encrypt = true
  }
}

# Credentials come from Vault, not from a tfvars file and not from the
# environment of whoever happens to be running this.
data "vault_kv_secret_v2" "grafana" {
  mount = "kv"
  name  = "observability/grafana"
}

data "vault_kv_secret_v2" "pagerduty" {
  mount = "kv"
  name  = "observability/pagerduty"
}

data "vault_kv_secret_v2" "slack" {
  mount = "kv"
  name  = "observability/slack"
}

provider "grafana" {
  url = var.grafana_url
  # A service-account token scoped to Admin on this org only. Not the admin
  # user's password, and not a token with instance-wide privileges.
  auth = data.vault_kv_secret_v2.grafana.data["provisioning_token"]
}

provider "vault" {
  # Address and token from VAULT_ADDR / VAULT_TOKEN. In CI the token comes from
  # a JWT/OIDC exchange (id_tokens in GitLab, id-token: write in GitHub) so no
  # static credential exists anywhere in the pipeline.
}
