variable "compartment_id" {
  description = "Compartment that owns the VCN and subnet."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every network resource name."
  type        = string
}

variable "vcn_cidr" {
  description = "VCN IPv4 CIDR."
  type        = string
}

variable "subnet_cidr" {
  description = "Public subnet IPv4 CIDR."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "The only source allowed to reach TCP/22."
  type        = string
}

variable "private_target_cidr" {
  description = "CIDR reachable on TCP/22 for jump traffic."
  type        = string
}

variable "vcn_dns_label" {
  description = "VCN DNS label."
  type        = string
}

variable "subnet_dns_label" {
  description = "Subnet DNS label."
  type        = string
}

variable "freeform_tags" {
  description = "Freeform tags applied to every network resource."
  type        = map(string)
}
