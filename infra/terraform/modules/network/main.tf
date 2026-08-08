# Network module — zone-segmented VLANs + firewall rules.
#
# Provider note: this uses vSphere + a generic firewall resource as the reference
# implementation (on-prem bank pattern). Swapping to AWS/Azure/Proxmox is a change
# INSIDE this module only — the interface (variables/outputs) stays the same, which
# is the entire point of keeping environments/ free of resource blocks.

locals {
  # Zones from docs/01-architecture.md §1. Order matters: index drives VLAN offset.
  zones = {
    dmz        = { vlan = var.vlan_base + 10, cidr = cidrsubnet(var.supernet, 4, 1) }
    app        = { vlan = var.vlan_base + 20, cidr = cidrsubnet(var.supernet, 4, 2) }
    data       = { vlan = var.vlan_base + 30, cidr = cidrsubnet(var.supernet, 4, 3) }
    management = { vlan = var.vlan_base + 40, cidr = cidrsubnet(var.supernet, 4, 4) }
  }

  common_tags = merge(var.tags, {
    module      = "network"
    environment = var.environment
  })
}

resource "vsphere_distributed_port_group" "zone" {
  for_each = local.zones

  name                            = "${var.environment}-${each.key}"
  distributed_virtual_switch_uuid = var.dvs_uuid
  vlan_id                         = each.value.vlan

  # Bank baseline: no promiscuous mode, no MAC spoofing, ever.
  allow_promiscuous      = false
  allow_forged_transmits = false
  allow_mac_changes      = false
}

# ---------------------------------------------------------------------------
# Firewall policy — DEFAULT DENY, then explicit allows.
# Each rule is intentionally verbose: an auditor reads this file.
# ---------------------------------------------------------------------------

locals {
  # inward-only traffic flow: internet -> dmz -> app -> data
  allow_rules = concat(
    [
      {
        name        = "internet-to-dmz-https"
        source      = "0.0.0.0/0"
        destination = local.zones.dmz.cidr
        ports       = ["443"]
        protocol    = "tcp"
        reason      = "Public HTTPS ingress, terminated at the reverse proxy/WAF"
      },
      {
        name        = "dmz-to-app"
        source      = local.zones.dmz.cidr
        destination = local.zones.app.cidr
        ports       = ["8080", "8443"]
        protocol    = "tcp"
        reason      = "Reverse proxy to application listeners"
      },
      {
        name        = "app-to-data-postgres"
        source      = local.zones.app.cidr
        destination = local.zones.data.cidr
        ports       = ["5432"]
        protocol    = "tcp"
        reason      = "Application to PostgreSQL (TLS enforced at the DB)"
      },
      {
        name        = "app-to-data-object-storage"
        source      = local.zones.app.cidr
        destination = local.zones.data.cidr
        ports       = ["9000"]
        protocol    = "tcp"
        reason      = "Application to MinIO S3 API"
      },
      {
        name        = "all-to-mgmt-vault"
        source      = "${local.zones.app.cidr},${local.zones.data.cidr}"
        destination = local.zones.management.cidr
        ports       = ["8200"]
        protocol    = "tcp"
        reason      = "Workloads fetch short-lived credentials from Vault"
      },
      {
        name        = "mgmt-to-all-observability"
        source      = local.zones.management.cidr
        destination = "${local.zones.dmz.cidr},${local.zones.app.cidr},${local.zones.data.cidr}"
        ports       = ["9100", "9090", "4317"]
        protocol    = "tcp"
        reason      = "Prometheus scrape + OTLP collection"
      },
      {
        name        = "bastion-ssh"
        source      = var.bastion_cidr
        destination = "${local.zones.dmz.cidr},${local.zones.app.cidr},${local.zones.data.cidr}"
        ports       = ["22"]
        protocol    = "tcp"
        reason      = "Break-glass SSH from the bastion only — see docs/09-runbooks.md §3"
      },
    ],
    var.extra_allow_rules
  )
}

resource "vsphere_nsxt_firewall_rule" "allow" {
  for_each = { for r in local.allow_rules : r.name => r }

  name             = "${var.environment}-${each.value.name}"
  section_id       = var.firewall_section_id
  action           = "ALLOW"
  source_cidrs     = split(",", each.value.source)
  destination_cidr = each.value.destination
  protocol         = each.value.protocol
  ports            = each.value.ports
  logged           = true # every allow is logged; SIEM needs the flow record
  description      = each.value.reason
}

# The final rule. Must be last (highest sequence) and must log — a spike in
# denies is one of the earliest signals of a misconfiguration or an intrusion.
resource "vsphere_nsxt_firewall_rule" "default_deny" {
  name             = "${var.environment}-default-deny-all"
  section_id       = var.firewall_section_id
  action           = "DROP"
  source_cidrs     = ["0.0.0.0/0"]
  destination_cidr = "0.0.0.0/0"
  protocol         = "any"
  ports            = []
  logged           = true
  sequence_number  = 65000
  description      = "Default deny. Do not add rules below this."
}

# Egress to the internet goes through an explicit forward proxy, never direct.
resource "vsphere_nsxt_firewall_rule" "egress_proxy_only" {
  name             = "${var.environment}-egress-via-proxy"
  section_id       = var.firewall_section_id
  action           = "ALLOW"
  source_cidrs     = [local.zones.app.cidr, local.zones.data.cidr]
  destination_cidr = var.forward_proxy_cidr
  protocol         = "tcp"
  ports            = ["3128"]
  logged           = true
  description      = "Outbound internet is proxied and allowlisted. No direct egress."
}
