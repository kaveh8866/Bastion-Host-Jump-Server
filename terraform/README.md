# OpenTofu / OCI — reserved for Stage 2

No infrastructure is defined or applied in Stage 1. This directory exists so
the provisioning layer has a stable home and the repository layout does not
change when Stage 2 begins.

## Planned resource graph

| Resource | Purpose |
| --- | --- |
| `oci_core_vcn` | Dedicated bastion VCN, disjoint from other CloudGuard projects |
| `oci_core_internet_gateway` + route table | Operator ingress and OS/image egress |
| `oci_core_security_list` | Ingress `2222/tcp` from one operator `/32` only; no `0.0.0.0/0` |
| `oci_core_subnet` | Public subnet for the bastion VNIC |
| `oci_core_instance` | `VM.Standard.A1.Flex` (ARM) preferred, `VM.Standard.E2.1.Micro` fallback |
| `oci_core_public_ip` (optional) | Stable operator endpoint across rebuilds |

Cloud-init will install Docker and start this Compose stack; it carries no
credential. Host keys and authorized keys are injected at runtime, never baked
into an image or user-data.

## Guardrails

- `bastion_allowed_cidr` must reject `0.0.0.0/0` in the variable definition.
- Prefer a reserved public IP so operators can pin a known host key/fingerprint.
- Keep state and `terraform.tfvars` local (gitignored); commit only examples.
- The live deployment and teardown are separate stages with their own evidence.

Until Stage 2 lands, `tofu`/`terraform` commands are not expected to run here.
