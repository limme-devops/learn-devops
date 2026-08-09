# Author: Mengty LIM
# k8s-cluster — provisions the NODES and the control-plane load balancer for an
# RKE2 cluster. It deliberately does NOT install RKE2: that is Ansible's job
# (playbooks/k8s-install.yml), and workloads are ArgoCD's job.
#
# Separation of concerns keeps the state file small and the blast radius tight.

locals {
  cluster_name = "${var.environment}-${var.cluster_suffix}"

  common_tags = merge(var.tags, {
    module      = "k8s-cluster"
    environment = var.environment
    cluster     = local.cluster_name
  })
}

# --- Control plane: always 3 (or 5) for etcd quorum -------------------------

module "control_plane" {
  source = "../compute-vm"

  environment    = var.environment
  role           = "${var.cluster_suffix}-cp"
  instance_count = var.control_plane_count

  cpu          = var.control_plane_cpu
  memory_mb    = var.control_plane_memory_mb
  root_disk_gb = 80
  data_disk_gb = 50 # dedicated etcd disk — etcd is fsync-latency sensitive

  golden_image_uuid = var.golden_image_uuid
  resource_pool_id  = var.resource_pool_id
  datastore_id      = var.etcd_datastore_id # fast, low-latency datastore
  port_group_id     = var.app_zone_port_group_id
  subnet_cidr       = var.app_zone_cidr
  ip_offset         = 10
  gateway_ip        = var.gateway_ip
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = var.placement_zones

  bootstrap_ssh_public_key = var.bootstrap_ssh_public_key
  tags                     = merge(local.common_tags, { k8s-role = "control-plane" })
}

# --- Workers ---------------------------------------------------------------

module "worker" {
  source   = "../compute-vm"
  for_each = var.worker_pools

  environment    = var.environment
  role           = "${var.cluster_suffix}-${each.key}"
  instance_count = each.value.count

  cpu          = each.value.cpu
  memory_mb    = each.value.memory_mb
  root_disk_gb = 100
  data_disk_gb = each.value.storage_gb

  golden_image_uuid = var.golden_image_uuid
  resource_pool_id  = var.resource_pool_id
  datastore_id      = var.datastore_id
  port_group_id     = var.app_zone_port_group_id
  subnet_cidr       = var.app_zone_cidr
  ip_offset         = each.value.ip_offset
  gateway_ip        = var.gateway_ip
  dns_servers       = var.dns_servers
  dns_domain        = var.dns_domain
  placement_zones   = var.placement_zones

  bootstrap_ssh_public_key = var.bootstrap_ssh_public_key
  tags = merge(local.common_tags, {
    k8s-role = "worker"
    k8s-pool = each.key
  })
}

# --- Control-plane API load balancer ---------------------------------------
# The kube-apiserver VIP. If this is a single point of failure, so is the
# cluster's control plane — keepalived pair, not a single box.

resource "haproxy_backend" "kube_apiserver" {
  name    = "${local.cluster_name}-apiserver"
  mode    = "tcp" # L4 passthrough: TLS terminates at the apiserver, not here
  balance = "roundrobin"

  dynamic "server" {
    for_each = module.control_plane.instances
    content {
      name  = server.key
      host  = server.value.ip
      port  = 6443
      check = true
    }
  }
}

resource "haproxy_frontend" "kube_apiserver" {
  name            = "${local.cluster_name}-apiserver"
  mode            = "tcp"
  bind_address    = var.apiserver_vip
  bind_port       = 6443
  default_backend = haproxy_backend.kube_apiserver.name
}

# RKE2 registration/supervisor port (9345) — needed for nodes to join.
resource "haproxy_backend" "rke2_supervisor" {
  name    = "${local.cluster_name}-supervisor"
  mode    = "tcp"
  balance = "roundrobin"

  dynamic "server" {
    for_each = module.control_plane.instances
    content {
      name  = server.key
      host  = server.value.ip
      port  = 9345
      check = true
    }
  }
}

resource "dns_a_record_set" "apiserver" {
  zone      = "${var.dns_domain}."
  name      = "${local.cluster_name}-api"
  addresses = [var.apiserver_vip]
  ttl       = 60 # low TTL: DR failover repoints this record
}

# --- Ingress VIP pool for MetalLB / LoadBalancer services ------------------

resource "dns_a_record_set" "ingress" {
  zone      = "${var.dns_domain}."
  name      = "*.${local.cluster_name}"
  addresses = [var.ingress_vip]
  ttl       = 300
}
