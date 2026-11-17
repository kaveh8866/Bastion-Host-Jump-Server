# Input contract for the OCI bastion environment.
#
# PORTABILITY: shared concepts keep provider-neutral names —
#   region                         -> AWS region / GCP region
#   vcn_cidr, subnet_cidr          -> VPC CIDR / subnetwork range
#   allowed_ssh_cidr               -> security-group or firewall source
#   instance_shape + ocpus/memory  -> instance type / machine type
#   ssh_public_key                 -> EC2 key pair / GCP SSH metadata
#
# Anything environment-specific belongs in terraform.tfvars, never in a module.

# -----------------------------------------------------------------------------
# OCI identity
# -----------------------------------------------------------------------------

variable "tenancy_ocid" {
  description = "OCI tenancy OCID. Also scopes the availability-domain lookup."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must be an OCI tenancy OCID."
  }
}

variable "compartment_ocid" {
  description = "Compartment OCID that owns the VCN, subnet and bastion instance."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", var.compartment_ocid))
    error_message = "compartment_ocid must be an OCI compartment (or tenancy) OCID."
  }
}

variable "region" {
  description = "OCI region identifier, e.g. eu-frankfurt-1."
  type        = string
  default     = "eu-frankfurt-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an OCI region identifier such as eu-frankfurt-1."
  }
}

variable "user_ocid" {
  description = "OCI user OCID for inline API-key auth. Leave null to use config_file_profile."
  type        = string
  default     = null
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API signing key. Leave null to use config_file_profile."
  type        = string
  default     = null
}

variable "private_key_path" {
  description = "Path to the OCI API signing key outside this repository. Leave null to use config_file_profile."
  type        = string
  default     = null
}

variable "config_file_profile" {
  description = "Profile inside ~/.oci/config. Leave null for the provider default."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Naming and tags
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Short slug used to prefix every resource name and the on-host install directory."
  type        = string
  default     = "cloudguard-bastion"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 2-31 characters."
  }
}

variable "environment" {
  description = "Environment suffix (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.environment))
    error_message = "environment must be lowercase alphanumeric with hyphens."
  }
}

variable "freeform_tags" {
  description = "Freeform tags applied to every resource (cost tracking / CloudGuard metadata)."
  type        = map(string)
  default = {
    project  = "bastion-host-jump-server"
    owner    = "cloudguard"
    tier     = "always-free"
    severity = "high"
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vcn_cidr" {
  description = "CIDR for the bastion VCN. Deliberately disjoint from other portfolio projects."
  type        = string
  default     = "10.8.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid IPv4 CIDR block."
  }
}

variable "subnet_cidr" {
  description = "CIDR for the public bastion subnet. Must sit inside vcn_cidr."
  type        = string
  default     = "10.8.1.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    The only source allowed to reach TCP/22. Use the operator's /32 (or a
    VPN/management CIDR), never 0.0.0.0/0. This is the perimeter control for
    the entire bastion.
  EOT
  type        = string

  validation {
    condition = (
      can(cidrhost(var.allowed_ssh_cidr, 0)) &&
      var.allowed_ssh_cidr != "0.0.0.0/0" &&
      var.allowed_ssh_cidr != "::/0"
    )
    error_message = "allowed_ssh_cidr must be a specific IPv4 CIDR (for example 203.0.113.10/32), never 0.0.0.0/0."
  }
}

variable "private_target_cidr" {
  description = "CIDR the bastion may reach on TCP/22 for jump traffic (the private subnet or a peered range)."
  type        = string
  default     = "10.8.0.0/16"

  validation {
    condition     = can(cidrhost(var.private_target_cidr, 0))
    error_message = "private_target_cidr must be a valid IPv4 CIDR block."
  }
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

variable "instance_shape" {
  description = "Compute shape. VM.Standard.A1.Flex is Always Free eligible (ARM); VM.Standard.E2.1.Micro is the trial/free fallback."
  type        = string
  default     = "VM.Standard.A1.Flex"

  validation {
    condition     = can(regex("^VM\\.Standard\\.[A-Za-z0-9.]+$", var.instance_shape))
    error_message = "instance_shape must look like VM.Standard.A1.Flex or VM.Standard.E2.1.Micro."
  }
}

variable "instance_ocpus" {
  description = "OCPUs for flexible shapes. One OCPU is ample for the small OpenSSH container."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "instance_ocpus must be between 1 and 4."
  }
}

variable "instance_memory_gbs" {
  description = "Memory in GB for flexible shapes. Six GB leaves room for Docker and the audit buffer."
  type        = number
  default     = 6

  validation {
    condition     = var.instance_memory_gbs >= 1 && var.instance_memory_gbs <= 24
    error_message = "instance_memory_gbs must be between 1 and 24."
  }
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size in GB. Holds Ubuntu, Docker and the bastion image."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_gbs >= 50 && var.boot_volume_size_gbs <= 200
    error_message = "boot_volume_size_gbs must be between 50 and 200."
  }
}

variable "availability_domain" {
  description = "Availability domain name. Leave null to use the first AD; pin another AD when A1 reports out of host capacity."
  type        = string
  default     = null
}

variable "hostname_label" {
  description = "VNIC hostname label (alphanumeric, starts with a letter, max 15 characters)."
  type        = string
  default     = "bastion"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{0,14}$", var.hostname_label))
    error_message = "hostname_label must be alphanumeric, start with a letter and be at most 15 characters."
  }
}

variable "ssh_public_key" {
  description = "SSH public key content (not a path, not a private key) injected into instance metadata."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key beginning with ssh-ed25519, ssh-rsa or ecdsa-sha2-*. Never paste a private key."
  }
}

variable "image_id" {
  description = "Pin a specific image OCID. Leave null to resolve the newest Ubuntu build compatible with the shape."
  type        = string
  default     = null
}

variable "image_operating_system" {
  description = "Operating system to resolve when image_id is null."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "image_operating_system_version" {
  description = "OS version to resolve when image_id is null."
  type        = string
  default     = "24.04"
}
