vsphere_server     = "vcenter-dc1.bank.internal"
vsphere_datacenter = "DC1"
vsphere_cluster    = "NONPROD-CLUSTER-01"

datastore_bulk    = "NONPROD-SAN-01"
golden_image_name = "rhel9-cis-l2-2026.07.15"

supernet            = "10.10.0.0/16"
vlan_base           = 1000
dvs_uuid            = "dvs-nonprod-01"
firewall_section_id = "fw-section-dev"
bastion_cidr        = "10.99.10.0/28"
forward_proxy_cidr  = "10.99.20.0/29"

apiserver_vip = "10.10.32.10"
ingress_vip   = "10.10.16.10"

dns_servers       = ["10.99.1.10", "10.99.1.11"]
dns_domain        = "dev.bank.internal"
dns_update_server = "10.99.1.10"

haproxy_dataplane_url = "https://lb-dev.bank.internal:5555"
