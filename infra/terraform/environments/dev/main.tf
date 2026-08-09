# Author: Mengty LIM
# DEV — same modules as prod, smaller shapes.
#
# Deliberately identical in STRUCTURE to prod. If dev is architecturally
# different from prod, dev stops being a useful test of prod. Only counts,
# sizes and retention differ.

locals {
  environment = "dev"

  tags = {
    owner       = "platform-engineering"
    cost-center = "CC-1042"
    data-class  = "internal" # dev never holds real customer data
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

data "vsphere_virtual_machine" "golden" {
  name          = var.golden_image_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

module "network" {
  source = "../../modules/network"

  environment         = local.environment
  supernet            = var.supernet
  vlan_base           = var.vlan_base
  dvs_uuid            = var.dvs_uuid
  firewall_section_id = var.firewall_section_id
  bastion_cidr        = var.bastion_cidr
  forward_proxy_cidr  = var.forward_proxy_cidr
  tags                = local.tags
}

module "k8s" {
  source = "../../modules/k8s-cluster"

  environment         = local.environment
  cluster_suffix      = "k8s"
  control_plane_count = 1 # dev tolerates a single control plane; prod never does

  worker_pools = {
    general = { count = 2, cpu = 4, memory_mb = 16384, storage_gb = 100, ip_offset = 40 }
  }

  apiserver_vip = var.apiserver_vip
  ingress_vip   = var.ingress_vip

  golden_image_uuid      = data.vsphere_virtual_machine.golden.id
  resource_pool_id       = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id           = data.vsphere_datastore.bulk.id
  etcd_datastore_id      = data.vsphere_datastore.bulk.id
  app_zone_port_group_id = module.network.zone_networks["app"].port_group_id
  app_zone_cidr          = module.network.zone_networks["app"].cidr
  gateway_ip             = cidrhost(module.network.zone_networks["app"].cidr, 1)
  dns_servers            = var.dns_servers
  dns_domain             = var.dns_domain
  placement_zones        = ["rack-a"]

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = local.tags
}

module "app_vms" {
  source = "../../modules/compute-vm"

  environment    = local.environment
  role           = "app"
  instance_count = 1
  cpu            = 2
  memory_mb      = 4096

  golden_image_uuid = data.vsphere_virtual_machine.golden.id
  resource_pool_id  = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id      = data.vsphere_datastore.bulk.id
  port_group_id     = module.network.zone_networks["app"].port_group_id
  subnet_cidr       = module.network.zone_networks["app"].cidr
  ip_offset         = 200
  gateway_ip        = cidrhost(module.network.zone_networks["app"].cidr, 1)
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = ["rack-a"]

  bootstrap_ssh_public_key = data.vault_kv_secret_v2.bootstrap.data["ssh_public_key"]
  tags                     = merge(local.tags, { tier = "app" })
}
