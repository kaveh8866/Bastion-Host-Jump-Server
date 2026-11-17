# Outputs an operator (or the next agent) needs to reach the host. Everything
# here is public information: IPs, OCIDs and an exposure inventory — never a
# credential, a private key or a command containing a secret.

output "instance_public_ip" {
  description = "Public IPv4 address of the OCI bastion host."
  value       = module.compute.public_ip
}

output "instance_private_ip" {
  description = "Private IPv4 address inside the bastion VCN."
  value       = module.compute.private_ip
}

output "instance_id" {
  description = "OCID of the compute instance."
  value       = module.compute.instance_id
}

output "instance_shape" {
  description = "Shape used, with flexible sizing when applicable."
  value       = "${var.instance_shape} (${var.instance_ocpus} OCPU / ${var.instance_memory_gbs} GB)"
}

output "availability_domain" {
  description = "Availability domain the instance landed in; pin it when A1 capacity is tight."
  value       = module.compute.availability_domain
}

output "vcn_id" {
  description = "OCID of the bastion VCN."
  value       = module.network.vcn_id
}

output "subnet_id" {
  description = "OCID of the public bastion subnet."
  value       = module.network.subnet_id
}

output "security_list_id" {
  description = "OCID of the security list enforcing the bastion perimeter."
  value       = module.network.security_list_id
}

output "ingress_ports" {
  description = "Inbound TCP ports actually opened. Only 22 is expected."
  value       = module.network.ingress_ports
}

output "ingress_exposure" {
  description = "Port/source pairs for an explicit exposure review. A world-open source here is a finding, not a setting."
  value       = module.network.ingress_sources
}

output "ssh_connection" {
  description = "Copy-paste SSH command for the host. The key stays on the operator workstation."
  value       = "ssh ubuntu@${module.compute.public_ip}"
}

output "deploy_next_step" {
  description = "What to do after apply. Deliberately carries no credential: .env and host keys are created on the host."
  value       = <<-EOT
    1. ssh ubuntu@${module.compute.public_ip}
    2. git clone https://github.com/kaveh8866/Bastion-Host-Jump-Server.git
    3. cd Bastion-Host-Jump-Server
    4. mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit
    5. cp .env.example .env && edit the bind address and audit paths
    6. add your public key to runtime/authorized_keys/bastion
    7. docker compose --env-file .env -f docker/docker-compose.yml up -d --build
  EOT
}
