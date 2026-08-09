# Author: Mengty LIM
# PROD environment values.
#
# NOTHING SECRET GOES IN THIS FILE. Credentials come from Vault (providers.tf).
# This file is committed on purpose: it is the reviewable record of what prod is.

vsphere_server     = "vcenter-dc1.bank.internal"
vsphere_datacenter = "DC1"
vsphere_cluster    = "PROD-CLUSTER-01"

datastore_bulk = "PROD-SAN-BULK-01"
datastore_fast = "PROD-NVME-FAST-01"

# Bump this to roll the fleet onto a new golden image. Because compute-vm
# ignores template_uuid changes, this alone will NOT recreate VMs — it takes a
# deliberate rolling replace through the deploy pipeline. That is intentional.
golden_image_name = "rhel9-cis-l2-2026.07.15"

supernet            = "10.20.0.0/16"
vlan_base           = 2000
dvs_uuid            = "dvs-prod-01"
firewall_section_id = "fw-section-prod"
bastion_cidr        = "10.99.10.0/28"
forward_proxy_cidr  = "10.99.20.0/29"

apiserver_vip = "10.20.32.10"
ingress_vip   = "10.20.16.10"

dns_servers       = ["10.99.1.10", "10.99.1.11"]
dns_domain        = "prod.bank.internal"
dns_update_server = "10.99.1.10"

haproxy_dataplane_url = "https://lb-prod.bank.internal:5555"

placement_zones = ["rack-a", "rack-b", "rack-c"]
