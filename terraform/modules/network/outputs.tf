output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.this.id
}

output "subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "security_list_id" {
  description = "OCID of the security list enforcing the perimeter."
  value       = oci_core_security_list.public.id
}

output "route_table_id" {
  description = "OCID of the public route table."
  value       = oci_core_route_table.public.id
}

output "ingress_ports" {
  description = "Inbound TCP ports admitted by the security list."
  value       = local.ingress_ports
}

output "ingress_sources" {
  description = "Port/source pairs for exposure review."
  value       = local.ingress_sources
}
