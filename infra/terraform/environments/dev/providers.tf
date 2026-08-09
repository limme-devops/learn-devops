# Author: Mengty LIM
terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    vsphere = { source = "hashicorp/vsphere", version = "~> 2.9" }
    vault   = { source = "hashicorp/vault", version = "~> 4.4" }
    dns     = { source = "hashicorp/dns", version = "~> 3.4" }
    haproxy = { source = "haproxytech/haproxy", version = "~> 1.0" }
  }
}

provider "vault" {
  skip_child_token = true
}

data "vault_kv_secret_v2" "vsphere" {
  mount = "kv"
  name  = "infra/dev/vsphere"
}

data "vault_kv_secret_v2" "bootstrap" {
  mount = "kv"
  name  = "infra/dev/bootstrap"
}

provider "vsphere" {
  user                 = data.vault_kv_secret_v2.vsphere.data["username"]
  password             = data.vault_kv_secret_v2.vsphere.data["password"]
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = false
}

provider "dns" {
  update {
    server        = var.dns_update_server
    key_name      = "terraform."
    key_algorithm = "hmac-sha256"
    key_secret    = data.vault_kv_secret_v2.vsphere.data["dns_tsig_key"]
  }
}

provider "haproxy" {
  url      = var.haproxy_dataplane_url
  username = data.vault_kv_secret_v2.vsphere.data["haproxy_user"]
  password = data.vault_kv_secret_v2.vsphere.data["haproxy_password"]
}
