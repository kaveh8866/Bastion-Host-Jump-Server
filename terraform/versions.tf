# =============================================================================
# Bastion Host / Jump Server — OpenTofu contract
# =============================================================================
# OCI is the validated target. The provider constraint accepts security fixes
# and patch releases but refuses a silent major-version change.
#
# PORTABILITY: replace the provider block and the two module bodies to target
# AWS or GCP; the root variable names and output names stay the same.
#
# State is local for this portfolio and is gitignored. For a shared environment,
# use an OCI Object Storage backend with state locking:
#
# backend "oci" {
#   bucket    = "cloudguard-bastion-tfstate"
#   namespace = "<object-storage-namespace>"
#   key       = "bastion/terraform.tfstate"
#   region    = "eu-frankfurt-1"
# }

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.20.0, < 8.0.0"
    }
  }
}
