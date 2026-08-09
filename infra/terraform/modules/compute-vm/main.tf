# Author: Mengty LIM
# compute-vm — a pool of identical VMs cloned from a Packer-built golden image.
#
# Design rule: this module never installs software. It produces hardware + an
# encrypted disk + a DNS record + an Ansible inventory entry. Configuration is
# Ansible's job (docs/05-cicd-automation.md §1).

locals {
  common_tags = merge(var.tags, {
    module      = "compute-vm"
    environment = var.environment
    role        = var.role
    managed_by  = "terraform"
  })

  # Deterministic naming: <env>-<role>-<zone-letter><index>
  # e.g. prod-app-a01. Predictable names make runbooks writable.
  instances = {
    for i in range(var.instance_count) :
    format("%s-%s-%s%02d", var.environment, var.role, substr(var.placement_zones[i % length(var.placement_zones)], -1, 1), i + 1) => {
      index = i
      zone  = var.placement_zones[i % length(var.placement_zones)]
      ip    = cidrhost(var.subnet_cidr, var.ip_offset + i)
    }
  }
}

resource "vsphere_virtual_machine" "this" {
  for_each = local.instances

  name             = each.key
  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id
  folder           = "${var.environment}/${var.role}"

  num_cpus = var.cpu
  memory   = var.memory_mb
  guest_id = var.guest_id
  firmware = "efi"

  # Secure Boot + vTPM: required for measured boot and LUKS key sealing.
  efi_secure_boot_enabled = true

  network_interface {
    network_id   = var.port_group_id
    adapter_type = "vmxnet3"
  }

  # Root disk from the golden image.
  disk {
    label            = "disk0"
    size             = var.root_disk_gb
    thin_provisioned = false # predictable IO for latency-sensitive workloads
  }

  # Data disk, encrypted at rest. Kept separate so it survives a VM rebuild —
  # this is what makes "rebuild rather than patch in place" viable.
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      label            = "disk1"
      size             = var.data_disk_gb
      unit_number      = 1
      thin_provisioned = false
    }
  }

  clone {
    template_uuid = var.golden_image_uuid

    customize {
      linux_options {
        host_name = each.key
        domain    = var.dns_domain
      }
      network_interface {
        ipv4_address = each.value.ip
        ipv4_netmask = tonumber(split("/", var.subnet_cidr)[1])
      }
      ipv4_gateway    = var.gateway_ip
      dns_server_list = var.dns_servers
    }
  }

  # Only the bootstrap SSH key goes in here — a key that is rotated after the
  # first Ansible run. No passwords, no application secrets. Ever.
  extra_config = {
    "guestinfo.bootstrap_pubkey" = var.bootstrap_ssh_public_key
    "guestinfo.environment"      = var.environment
    "guestinfo.role"             = var.role
  }

  tags = [for k, v in local.common_tags : "${k}:${v}"]

  lifecycle {
    # A golden-image bump must not silently recreate the whole prod fleet during
    # an unrelated apply. Roll the fleet deliberately via the deploy pipeline.
    ignore_changes = [clone[0].template_uuid, extra_config]

    precondition {
      condition     = var.environment != "prod" || var.instance_count >= 2
      error_message = "Production roles must have at least 2 instances for availability."
    }
  }
}

resource "vsphere_virtual_machine_snapshot" "pre_change" {
  for_each = var.take_pre_change_snapshot ? local.instances : {}

  virtual_machine_uuid = vsphere_virtual_machine.this[each.key].uuid
  snapshot_name        = "pre-change-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  description          = "Automatic pre-change snapshot. NOT a backup — see docs/07-backup-dr.md §1."
  memory               = false
  quiesce              = true
  consolidate          = true
  remove_children      = true
}

resource "dns_a_record_set" "this" {
  for_each = local.instances

  zone      = "${var.dns_domain}."
  name      = each.key
  addresses = [each.value.ip]
  ttl       = 300
}
