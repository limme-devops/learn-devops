# PROD — composition only. No `resource` blocks belong in this file.
# If you find yourself writing one, it belongs in a module.

locals {
  environment = "prod"

  tags = {
    owner       = "platform-engineering"
    cost-center = "CC-1042"
    data-class  = "restricted" # drives datastore encryption + retention policy
    compliance  = "pci-dss,iso27001"
    managed_by  = "terraform"
    repo        = "learn-devops/infra/terraform"
  }
}

data "vsphere_datacenter" "dc" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.vsphere_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "bulk" {
  name          = var.datastore_bulk
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "fast" {
  name          = var.datastore_fast
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "golden" {
  name          = var.golden_image_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# --- Layer 1: network zones + firewall -------------------------------------

module "network" {
  source = "../../modules/network"

  environment         = local.environment
  supernet            = var.supernet
  vlan_base           = var.vlan_base
  dvs_uuid            = var.dvs_uuid
  firewall_section_id = var.firewall_section_id
  bastion_cidr        = var.bastion_cidr
  forward_proxy_cidr  = var.forward_proxy_cidr

  extra_allow_rules = [
    {
      name        = "app-to-keycloak"
      source      = cidrsubnet(var.supernet, 4, 2)
      destination = cidrsubnet(var.supernet, 4, 4)
      ports       = ["8443"]
      protocol    = "tcp"
      reason      = "Applications validate OIDC tokens against Keycloak JWKS endpoint"
    },
  ]

  tags = local.tags
}

# --- Layer 2: Kubernetes cluster -------------------------------------------

module "k8s" {
  source = "../../modules/k8s-cluster"

  environment         = local.environment
  cluster_suffix      = "k8s"
  control_plane_count = 3

  worker_pools = {
    # General application workloads.
    general = { count = 6, cpu = 16, memory_mb = 65536, storage_gb = 200, ip_offset = 40 }
    # Tainted for stateful sets (PostgreSQL, MinIO, Kafka) — local NVMe, no overcommit.
    data = { count = 4, cpu = 16, memory_mb = 131072, storage_gb = 2000, ip_offset = 80 }
    # Ingress tier, sits closest to the DMZ boundary.
    ingress = { count = 3, cpu = 8, memory_mb = 16384, storage_gb = 100, ip_offset = 120 }
  }

  apiserver_vip = var.apiserver_vip
  ingress_vip   = var.ingress_vip

  golden_image_uuid      = data.vsphere_virtual_machine.golden.id
  resource_pool_id       = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id           = data.vsphere_datastore.bulk.id
  etcd_datastore_id      = data.vsphere_datastore.fast.id
  app_zone_port_group_id = module.network.zone_networks["app"].port_group_id
  app_zone_cidr          = module.network.zone_networks["app"].cidr
  gateway_ip             = cidrhost(module.network.zone_networks["app"].cidr, 1)
  dns_servers            = var.dns_servers
  dns_domain             = var.dns_domain
  placement_zones        = var.placement_zones

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = local.tags
}

# --- Layer 3: VM track — the classic three-tier deployment ------------------

module "loadbalancer_vms" {
  source = "../../modules/compute-vm"

  environment    = local.environment
  role           = "lb"
  instance_count = 2 # keepalived pair
  cpu            = 4
  memory_mb      = 8192

  golden_image_uuid = data.vsphere_virtual_machine.golden.id
  resource_pool_id  = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id      = data.vsphere_datastore.bulk.id
  port_group_id     = module.network.zone_networks["dmz"].port_group_id
  subnet_cidr       = module.network.zone_networks["dmz"].cidr
  ip_offset         = 20
  gateway_ip        = cidrhost(module.network.zone_networks["dmz"].cidr, 1)
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = var.placement_zones

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = merge(local.tags, { tier = "dmz" })
}

module "app_vms" {
  source = "../../modules/compute-vm"

  environment    = local.environment
  role           = "app"
  instance_count = 4
  cpu            = 8
  memory_mb      = 32768
  data_disk_gb   = 100

  golden_image_uuid = data.vsphere_virtual_machine.golden.id
  resource_pool_id  = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id      = data.vsphere_datastore.bulk.id
  port_group_id     = module.network.zone_networks["app"].port_group_id
  subnet_cidr       = module.network.zone_networks["app"].cidr
  ip_offset         = 200 # keep clear of the k8s pools above
  gateway_ip        = cidrhost(module.network.zone_networks["app"].cidr, 1)
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = var.placement_zones

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = merge(local.tags, { tier = "app" })
}

module "db_vms" {
  source = "../../modules/compute-vm"

  environment    = local.environment
  role           = "db"
  instance_count = 3 # primary + sync standby + async standby
  cpu            = 16
  memory_mb      = 65536
  data_disk_gb   = 2000

  golden_image_uuid = data.vsphere_virtual_machine.golden.id
  resource_pool_id  = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id      = data.vsphere_datastore.fast.id
  port_group_id     = module.network.zone_networks["data"].port_group_id
  subnet_cidr       = module.network.zone_networks["data"].cidr
  ip_offset         = 20
  gateway_ip        = cidrhost(module.network.zone_networks["data"].cidr, 1)
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = var.placement_zones

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = merge(local.tags, { tier = "data", backup-tier = "0" })
}
