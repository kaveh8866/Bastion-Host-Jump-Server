# OCI network module — public VCN with one public subnet and one ingress rule.
#
# PORTABILITY:
#
#   | OCI (here)                | AWS                        | GCP                             |
#   | ------------------------- | -------------------------- | ------------------------------- |
#   | oci_core_vcn              | aws_vpc                    | google_compute_network          |
#   | oci_core_internet_gateway | aws_internet_gateway       | (implicit default route)        |
#   | oci_core_route_table      | aws_route_table + aws_route| google_compute_route            |
#   | oci_core_security_list    | aws_security_group + rules | google_compute_firewall         |
#   | oci_core_subnet           | aws_subnet                 | google_compute_subnetwork       |
#
# The ingress contract is one TCP/22 rule from allowed_ssh_cidr. On AWS this is
# one ingress rule on the bastion security group; on GCP it is one ingress
# firewall rule with source_ranges = [var.allowed_ssh_cidr].
#
# SECURITY POSTURE:
#   Inbound 22/tcp from allowed_ssh_cidr only.
#   No inbound 80/443, no ICMP, no management ports.
#   Outbound is explicit: 22 to the private target, 80/443 for OS and image
#   pulls, and 53 for DNS. There is no catch-all egress rule.
#
# The host SSH daemon owns 22. The Compose stack's OpenSSH listener (2222) is
# loopback-bound by default; a deployment stage that exposes the container must
# change the host mapping and add a deliberate rule, not widen this one.

locals {
  ingress_ports = [22]

  ingress_sources = [
    {
      port   = 22
      source = var.allowed_ssh_cidr
    }
  ]
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = var.vcn_dns_label
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

# Dedicated route table instead of mutating the VCN default, so routing intent is
# visible in the plan and the VCN remains reusable.
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-public-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
    description       = "Default IPv4 egress to the internet gateway"
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-sl"
  freeform_tags  = var.freeform_tags

  # The perimeter: exactly one inbound service, from exactly one CIDR.
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.allowed_ssh_cidr
    source_type = "CIDR_BLOCK"
    description = "Bastion SSH from the operator/management CIDR only"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # SSH to private jump targets. Scoped to the private range, not the internet.
  egress_security_rules {
    protocol         = "6"
    destination      = var.private_target_cidr
    destination_type = "CIDR_BLOCK"
    description      = "Jump traffic to private SSH targets"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Package and container-image retrieval. Both are needed during first boot.
  egress_security_rules {
    protocol         = "6"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "OS package retrieval (HTTP)"

    tcp_options {
      min = 80
      max = 80
    }
  }

  egress_security_rules {
    protocol         = "6"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "OS/package and container registry retrieval (HTTPS)"

    tcp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    protocol         = "17" # UDP
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "DNS resolution"

    udp_options {
      min = 53
      max = 53
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.name_prefix}-public-subnet"
  dns_label                  = var.subnet_dns_label
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}
