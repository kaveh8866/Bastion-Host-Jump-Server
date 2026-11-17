# OpenTofu / OCI — Stage 2

**Status:** configuration complete and validated with `tofu validate`; **no
resources were planned, applied or destroyed** in this stage. State remains
local and gitignored, and no OCI credential is stored in this directory.

## Resource graph

```
root
├── module.network
│   ├── oci_core_vcn                10.8.0.0/16
│   ├── oci_core_internet_gateway   egress path for updates and image pulls
│   ├── oci_core_route_table        0.0.0.0/0 -> IGW
│   ├── oci_core_security_list      TCP/22 ingress, explicit egress
│   └── oci_core_subnet             10.8.1.0/24 public subnet
└── module.compute
    ├── oci_identity_availability_domains (data)
    ├── oci_core_images (Ubuntu 24.04, shape-compatible)
    └── oci_core_instance           VM.Standard.A1.Flex, 1 OCPU / 6 GB
```

## Perimeter contract

The security list is intentionally tiny:

| Direction | Protocol / port | Destination / source | Why |
| --- | --- | --- | --- |
| Ingress | TCP/22 | `allowed_ssh_cidr` only | The sole administrative entrance |
| Egress | TCP/22 | `private_target_cidr` | Jump traffic to private SSH targets |
| Egress | TCP/80, 443 | `0.0.0.0/0` | OS packages and container image pulls |
| Egress | UDP/53 | `0.0.0.0/0` | DNS resolution |

There is **no ingress 80/443**, no ICMP, no management port, no catch-all
egress rule, and `allowed_ssh_cidr` validation refuses `0.0.0.0/0` and `::/0`.

The OCI host SSH daemon owns TCP/22. The Stage 1 container publishes
`127.0.0.1:2222` by default, so it is not reachable through the security list
until a deployment stage deliberately changes the mapping. Do not add 2222 to
the perimeter without a separate decision.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `tenancy_ocid`, `compartment_ocid` | required | Placeholders in `terraform.tfvars.example` |
| `region` | `eu-frankfurt-1` | OCI region identifier |
| `allowed_ssh_cidr` | required | Operator `/32` or VPN management CIDR; world-open refused |
| `ssh_public_key` | required | Public key content, never a private key |
| `vcn_cidr` / `subnet_cidr` | `10.8.0.0/16` / `10.8.1.0/24` | Disjoint from other CloudGuard projects |
| `private_target_cidr` | `10.8.0.0/16` | Destination allowed on TCP/22 |
| `instance_shape` | `VM.Standard.A1.Flex` | Always Free ARM; `VM.Standard.E2.1.Micro` fallback |
| `instance_ocpus` / `instance_memory_gbs` | `1` / `6` | Flexible-shape sizing |
| `boot_volume_size_gbs` | `50` | Ubuntu boot volume |
| `availability_domain` | `null` | Pin another AD when A1 capacity is tight |
| `image_id` | `null` | Pin an image; otherwise resolve newest compatible Ubuntu 24.04 |
| `hostname_label` | `bastion` | VNIC label, max 15 characters |

`terraform.tfvars` is gitignored. Only the placeholder example is tracked.

## Run

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit tenancy, compartment, operator CIDR and public key
tofu init
tofu fmt -recursive -check
tofu validate
tofu plan        # requires OCI credentials; not run in Stage 2
```

The `ocid1.*.placeholder-not-a-real-ocid` values are deliberately invalid.
Never commit `terraform.tfvars`, a private key, an API signing key or state.

## State

State is local (`terraform.tfstate`, gitignored) for this portfolio. The
`versions.tf` comment contains the OCI Object Storage backend shape for a
shared environment. Provider selection is locked in `.terraform.lock.hcl`.

## Portability — AWS / GCP

| Concept | OCI (this module) | AWS | GCP |
| --- | --- | --- | --- |
| Network | `oci_core_vcn` | `aws_vpc` | `google_compute_network` |
| Gateway / route | IGW + route table | IGW + route table | implicit default route |
| Firewall | security list | security group + rules | firewall rules |
| Subnet | `oci_core_subnet` | `aws_subnet` | `google_compute_subnetwork` |
| Compute | `oci_core_instance` | `aws_instance` (`t4g.small` / `t3.micro`) | `google_compute_instance` (`e2-micro`) |
| Sizing | `shape` + `shape_config` | `instance_type` | `machine_type` |
| Bootstrap | `metadata.user_data` (base64) | `user_data` | `metadata_startup_script` |
| Admin source | `allowed_ssh_cidr` | security-group CIDR | firewall `source_ranges` |

The root variables and outputs stay the same; replace the two module bodies and
the provider block. Keep the single-source ingress and explicit egress pattern.

## Cloud-init

`cloud-init.yaml.tftpl` prepares the host only: Docker and Compose, a hardened
Docker daemon config, SSH hardening, unattended security updates and an empty
`/opt/cloudguard-bastion/runtime` directory. It carries no credential, host key,
authorized key or `.env`; those are created over SSH in the deployment stage.

## Validation evidence

```
$ tofu fmt -recursive -check
(no output; exit 0)

$ tofu validate
Success! The configuration is valid.
```

`tofu init -backend=false` completed and generated `.terraform.lock.hcl`.
`tofu plan` was not run: Stage 2 is the IaC contract, and no OCI resources or
credentials were used to create them. Live plan/apply belongs to Stage 5.
