# Bastion Host / Jump Server

![Alpine](https://img.shields.io/badge/base-Alpine%203.23-0D597F?logo=alpine-linux&logoColor=white)
![OpenSSH](https://img.shields.io/badge/access-public--key%20only-4E9A06)
![Docker](https://img.shields.io/badge/Docker-read--only%20%2B%20cap__drop%20ALL-2496ED?logo=docker&logoColor=white)
![OpenTofu](https://img.shields.io/badge/IaC-OpenTofu-844FBA?logo=opentofu&logoColor=white)
![Stage](https://img.shields.io/badge/stage-8%20%C2%B7%20v1.0.1%20certified-green)
![License](https://img.shields.io/badge/license-MIT-green)

A small, hardened SSH jump host for reaching private cloud resources without
exposing them. Administrators authenticate with a public key, land in an
audited session, and forward TCP/22 to private hosts; password authentication,
root login, SFTP, agent forwarding and reverse tunnels are disabled.

**Stage 8 status — v1.0.1 certified release:** the independent Git repository
is on `main`, the remote is configured, the MIT license is present, and the
release is tagged `v1.0.1`. The Stage 5 retry on 2026-11-17 successfully created
the OCI host and completed live SSH, audit, jump and port-restriction checks.
Local Stage 4 verification and the Stage 6 teardown of the earlier attempt
remain valid. The official CloudGuard audit passed **5/5** and recorded
**`PORTABLE_CERTIFIED` — 100/100** on 2026-11-17. The verified host was torn
down on 2026-11-18; the certification rests on the recorded live evidence, not
on a running deployment.

---

## Overview

This repository packages a single-account OpenSSH bastion as a small hardened
container, with a declarative access policy and an OpenTofu deployment
contract. It is designed for the smallest useful cloud footprint: an SSH
process, a few administrative sessions and an append-only audit trail.

| Goal | Implementation |
| --- | --- |
| Reduce the exposure surface | One TCP/22 ingress rule; no HTTP, ICMP or management ports |
| Remove password risk | Public-key only, no root login, no keyboard-interactive fallback |
| Make sessions accountable | `ForceCommand` writes a JSONL record before executing the session |
| Limit blast radius | One allowlisted account, read-only rootfs, `cap_drop: ALL`, no-new-privileges |
| Keep secrets out of Git | Strict `.gitignore`; runtime keys, audit data, state and `.env` are ignored |
| Stay portable | Provider-neutral OpenTofu variables and module boundaries |

---

## Secure proxy workflow

```text
[Authorized Operators / Admins]
              │
              │  Encrypted SSH / key-based authentication
              │  Cloud ingress: TCP/22 from approved management CIDR only
              ▼
[Hardened Bastion Host / Jump Server]
  ├── Host sshd on 22 (or container sshd on loopback 2222 locally)
  ├── AllowUsers bastion · PermitRootLogin no · PasswordAuthentication no
  ├── ForceCommand session-audit ──► runtime/audit/sessions.jsonl
  └── PermitOpen *:22 (forwarding to the private network only)
              │
              │  SSH / TCP forwarding to port 22
              ▼
[Internal / Private Network & Subnet Resources]
```

The cloud firewall is the perimeter: the OCI security list admits only TCP/22
from `allowed_ssh_cidr`. The container is published on `127.0.0.1:2222` by
default. The host SSH daemon and the container listener are deliberately
separate; the Terraform stack does not expose 2222.

---

## Features

- Multi-arch Alpine/OpenSSH image with no compiler or package cache
- Public-key-only authentication, no root, no password, one allowlisted user
- TCP forwarding enabled but restricted to target port 22; reverse tunnels,
  agent forwarding, X11 and SFTP disabled
- Structured JSONL session audit, fail-closed if the audit volume is unwritable
- Read-only root filesystem, only four sshd capabilities retained,
  `no-new-privileges`, PID/memory/CPU limits and bounded logs
- Versioned whitelist schema plus a `jq` validator that rejects malformed
  addresses and world-open CIDRs
- OpenTofu OCI network, security list, subnet and Always-Free-compatible compute
- Local and OCI verification evidence in `docs/`; no secrets or runtime data in Git

---

## Quick start (local)

Requirements: Docker 24+ with Compose v2, an OpenSSH client, and free loopback
port `2222`.

```bash
cd projects/08-bastion-host-jump-server

mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit

# Generate an operator key once. The private half stays in ~/.ssh.
ssh-keygen -t ed25519 -a 100 -C "bastion-admin" -f ~/.ssh/bastion_admin
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion
chmod 0644 runtime/authorized_keys/bastion

cp -n .env.example .env
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml ps   # wait for healthy

ssh -p 2222 -i ~/.ssh/bastion_admin bastion@127.0.0.1 'id -un'
# bastion
```

The first start generates an ed25519 host key under `runtime/host_keys`. The
entrypoint stages public keys as `root:root 0644` so `StrictModes` works even
when the source is a Windows bind mount. Restart the container after a key
change.

Use the container as a jump host:

```bash
ssh -J bastion@<bastion-host>:2222 -i ~/.ssh/bastion_admin ubuntu@10.0.0.10
```

For a cloud host, the host sshd owns TCP/22 and the container remains
loopback-bound on 2222. Do not change `BASTION_SSH_BIND_ADDRESS` to `0.0.0.0`
unless the cloud firewall explicitly admits the mapped port; the default
Terraform perimeter admits only 22.

The repository root also has a thin `docker-compose.yml` that extends the
canonical service definition for portfolio discovery; both entrypoints resolve
the same `runtime/` mounts.

Stop the local stack without deleting runtime material:

```bash
docker compose --env-file .env -f docker/docker-compose.yml down
```

---

## SSH access policy and key management

### Policy

| Control | Default |
| --- | --- |
| Ingress | TCP/22 from the approved `/32` or VPN management range only |
| Account | `AllowUsers bastion`; root login disabled |
| Authentication | `PubkeyAuthentication yes`; passwords and keyboard-interactive off |
| Forwarding | `AllowTcpForwarding yes`, `PermitOpen *:22`; reverse tunnels disabled |
| Agent / X11 / SFTP | Disabled |
| Key location | `/run/authorized_keys/bastion` staged from the host mount |
| Session hook | `ForceCommand /usr/local/bin/session-audit`, fail-closed |

The `terraform/` security list is the packet-level source-CIDR control. The
whitelist JSON is a declarative policy input, not a replacement firewall.

### Authorized keys

```bash
# Add or rotate the public key; never put the private key under runtime/.
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion
chmod 0644 runtime/authorized_keys/bastion

# The entrypoint stages keys at container start.
docker compose --env-file .env -f docker/docker-compose.yml restart bastion
docker exec cg-bastion sh -c 'ls -l /run/authorized_keys; ssh-keygen -lf /run/authorized_keys/bastion'
```

Only public key material belongs in `runtime/authorized_keys/`. The private
half stays in `~/.ssh` (or an agent) and is never copied into Git, the image or
`user_data`.

### Access policy validation

```bash
# Requires jq on the host; the image also ships jq.
./bastion/access/validate-whitelist.sh bastion/access/whitelist.example.json
# whitelist valid: ...
```

The validator rejects `0.0.0.0/0` and octets outside 0–255. The Terraform
`allowed_ssh_cidr` variable independently rejects the IPv4 default route.

---

## Session audit and monitoring

Every interactive or command session writes one JSON object before execution:

```json
{"timestamp":"2026-11-17T20:09:48Z","user":"bastion","source":"172.24.0.1","action":"command","command":"id -un; echo stage4-ok"}
```

```bash
# Host-side record (gitignored)
tail -n 20 runtime/audit/sessions.jsonl

# Parse inside the container as the audit owner
MSYS_NO_PATHCONV=1 docker exec --user 1000 cg-bastion \
  jq -r '[.timestamp,.user,.source,.action,.command] | @tsv' \
  /var/log/bastion/sessions.jsonl

# Authentication and session metadata
docker logs --since 15m cg-bastion 2>&1 | \
  grep -E 'Accepted publickey|Failed publickey|Invalid user|Starting session|Disconnected'

# Active process tree
docker top cg-bastion
```

The hook fails closed: if the audit volume is not writable, the session is
denied. Audit records can contain command arguments and must remain on the
host or be shipped to controlled storage; never commit them.

Two limitations are deliberate and documented:

- Docker port publishing NATs the connection, so the local source is often
  `172.24.0.1` (the bridge gateway). Use host networking or a forwarding proxy
  if true client-IP attribution is required.
- OpenSSH handles `-W`/`ProxyJump` channels before `ForceCommand`; those appear
  in the `VERBOSE` sshd log but do not create a JSONL command record.

---

## OpenTofu / OCI deployment

The infrastructure contract lives in [`terraform/`](terraform/README.md):

- VCN `10.8.0.0/16`, public subnet `10.8.1.0/24`
- Internet gateway and dedicated public route table
- One security list ingress rule: **TCP/22 from `allowed_ssh_cidr`**
- Explicit egress: TCP/22 to the private target range, HTTP/HTTPS for packages,
  UDP/53 for DNS
- Ubuntu 24.04 compute, `VM.Standard.A1.Flex` by default, E2.1.Micro fallback

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
# set tenancy, compartment, region, operator CIDR and public key
tofu init
tofu fmt -recursive -check
tofu validate
tofu plan
```

`tofu apply` is a deployment action and requires an approved plan. The desired
outputs are `instance_public_ip`, `instance_private_ip`, `instance_id` and the
network identifiers.

**Stage 5 live retry — succeeded on 2026-11-17:** A1.Flex capacity became
available in `jiTx:EU-FRANKFURT-1-AD-1`. A saved plan created all six resources;
cloud-init completed and the remote Docker stack became healthy.

| Check | Result |
| --- | --- |
| Instance | `VM.Standard.A1.Flex`, 1 OCPU / 6 GB, AD-1 |
| Public / private IP | `132.145.249.219` / `10.8.1.34` |
| Host bootstrap | `cloud-init status --wait` → `done`; Docker 29.1.3 active |
| Container | `cg-bastion` healthy; `127.0.0.1:2222->2222/tcp` |
| Authentication | valid key `0`; missing/password, invalid key and root all `255` |
| Audit | live JSONL record written for the command session |
| Jump | disposable target reached through the bastion; `stage5-jump-ok` |
| Port restriction | target port 23 rejected: `administratively prohibited` |
| IaC drift | post-apply refresh plan: **no changes** |

The earlier attempt was blocked in every AD by A1 `500-InternalError` capacity
errors and E2 `400-LimitExceeded` tenancy limits. No paid shape was substituted.
The earlier Stage 6 teardown destroyed the first attempt's five network
resources; the retry created a fresh stack, which was itself retired after
certification. See
[`docs/stage-5-retry-verification.txt`](docs/stage-5-retry-verification.txt),
[`docs/stage-5-verification.txt`](docs/stage-5-verification.txt) and
[`docs/stage-6-verification.txt`](docs/stage-6-verification.txt).

**Final teardown — 2026-11-18:** the certified stack was destroyed to stop idle
spend and avoid drift before Project 09. `tofu destroy` removed all six
resources; `tofu state list` is empty, the former public IP no longer accepts
TCP/22, and a read-only OCI inventory reports the instance `TERMINATED` with
zero VCNs and zero active instances in the compartment. All verification logs
are preserved. See
[`docs/stage-8-teardown-verification.txt`](docs/stage-8-teardown-verification.txt).

---

## Cloud-Agnostic Portability Note

The container and OpenTofu modules are **Cloud-Agnostic**: AWS, GCP and OCI are
supported deployment targets through provider-specific network/compute modules
while the root variable and output contract remains stable.

**Final production verification and testing certification are performed
strictly on Oracle Cloud Infrastructure (OCI) using trial credits.** AWS and
GCP are ports, not certified targets.

In short: final production verification and testing certification are performed
strictly on OCI using trial credits; no AWS or GCP certification run is claimed.

**Current certification status:** **`PORTABLE_CERTIFIED` — 100/100 (5/5
checks)**, audited 2026-11-17 by the CloudGuard portability audit. Live OCI
verification is complete. No AWS or GCP certification run is claimed.

### AWS migration tips

- Replace the `network` module with a VPC, public subnet, route table, internet
  gateway and a security group whose only ingress is TCP/22 from the same
  management CIDR.
- Replace `oci_core_instance` with `aws_instance` (`t4g.small` or `t3.micro`),
  map `ssh_public_key` to an EC2 key pair and `user_data` to instance user-data.
- Use a 50 GB gp3 boot volume for parity; keep the container’s 2222 listener on
  loopback and expose only host SSH 22.
- Keep the account, key, audit and forwarding policy unchanged; only the
  provider module should change.

### GCP migration tips

- Replace the network module with a VPC network, subnetwork and a firewall rule
  whose source ranges are `allowed_ssh_cidr` and whose target is TCP/22.
- Replace `oci_core_instance` with `google_compute_instance` (`e2-micro` or
  `e2-small`), mapping SSH metadata and the startup script to the same
  cloud-init contract.
- Use a 30 GB standard persistent disk for the free-tier equivalent; add a
  deliberate firewall rule before exposing the host.
- Preserve the same account, key staging and JSONL audit behavior.

---

## 💰 Cross-Cloud Cost & Benchmark Estimation

The table uses the configured footprint of this project — **1 vCPU, 6 GB RAM,
50 GB boot disk, SSH-only network** — and the closest free-tier equivalent on
each provider. These are **list-price estimates, not live benchmark results**;
the live OCI instance confirms the shape fits the Always Free allowance, but no
throughput benchmark was run. Prices are USD, exclude tax, and were reviewed on
**2026-11-17**.

| Provider / offer | vCPU | RAM | Boot disk | Monthly egress included | Estimated monthly |
| --- | ---: | ---: | ---: | ---: | ---: |
| **OCI Always Free** — A1.Flex fit | 1 OCPU (within 2 OCPU / 12 GB monthly allowance) | 6 GB | 50 GB (within 200 GB) | 10 TB/month | **$0** |
| **OCI Free Trial** — same footprint | 1 OCPU | 6 GB | 50 GB | 10 TB/month | **$0 incremental** within US$300 / 30-day credit |
| **AWS** — t3.micro + gp3 | 2 burstable vCPU | 1 GB | 50 GB gp3 | 100 GB/month free, then $0.09/GB | **≈ $11.59** + excess egress |
| **GCP** — e2-micro + standard PD | 2 shared vCPU | 1 GB | 30 GB standard | 1 GB/month free, then about $0.12/GiB (Premium tier) | **$0** in eligible US free-tier region; **≈ $6.11** paid compute + disk/egress |

Assumptions and calculations:

- AWS: `t3.micro` at $0.0104/hour × 730 hours = **$7.59**; 50 GB gp3 × $0.08/GB-month
  = **$4.00**; total **$11.59** before egress beyond 100 GB.
- GCP: `e2-micro` list price ≈ **$6.11/month** in `us-central1`; the free tier
  includes one e2-micro, 30 GB standard PD and 1 GB North American egress in
  `us-west1`, `us-central1` or `us-east1`.
- OCI: the 1 OCPU / 6 GB / 50 GB configuration fits the current Always Free
  allowance (2 OCPU, 12 GB, 200 GB, 10 TB egress); the trial credit is separate
  and time-limited.
- SSH-only traffic is assumed; hosted workloads, backups, snapshots, public
  IPv4 charges, monitoring and support are not included.
- The local container is capped at 0.50 CPU / 256 MiB; that is a runtime
  envelope, not a cloud instance benchmark.

Pricing references:

- [Oracle Cloud Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
  and [Free Tier FAQ](https://www.oracle.com/cloud/free/faq/)
- [AWS EC2 on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
  [EBS pricing](https://aws.amazon.com/ebs/pricing/) and
  [data transfer pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [Google Cloud Free Tier](https://cloud.google.com/free/docs/free-cloud-features),
  [Compute Engine pricing](https://cloud.google.com/compute/pricing) and
  [disk pricing](https://cloud.google.com/compute/disks-image-pricing)

Provider prices and free-tier terms change; confirm the exact region and
allowance in the provider calculator before budgeting.

---

## Security controls

| Control | Observed / configured |
| --- | --- |
| Root filesystem | `ReadonlyRootfs=true` |
| Capabilities | `CapDrop=[ALL]`; retained `CHOWN`, `SETGID`, `SETUID`, `SYS_CHROOT` |
| Privilege escalation | `no-new-privileges:true` |
| PIDs / memory / CPU | 128 / 256 MiB / 0.50 CPU |
| Root login | `permitrootlogin no` |
| Passwords | `passwordauthentication no`; keyboard-interactive off |
| Public keys | `pubkeyauthentication yes`; `/run/authorized_keys/%u` |
| Account allowlist | `allowusers bastion` |
| Forwarding | `allowtcpforwarding yes`, `permitopen *:22`; reverse tunnels off |
| Audit | `forcecommand /usr/local/bin/session-audit`; JSONL before exec |
| Host keys | Generated on first start into a mount; never baked into the image |
| Logs | `json-file`, 10 MiB × 3 |
| Git boundary | `.env`, runtime keys/audit, state, tfvars, PEM/key files ignored |

### Zero-leak audit (Stage 7)

- 44 tracked files including this Stage 7 transcript; **0** forbidden tracked paths.
- `.env.example` and `terraform/terraform.tfvars.example` are the only tracked
  templates; both contain placeholders only.
- `git check-ignore` confirms `.env`, tfvars, state, host keys, authorized
  keys and audit JSONL are ignored.
- No PEM/private-key header is present in tracked content. The only grep hits
  are the literal scan commands recorded in Stage 4 evidence.
- Full results: [`docs/stage-7-verification.txt`](docs/stage-7-verification.txt).

---

## Repository layout

```text
.
├── docker-compose.yml          Root entrypoint extending docker/docker-compose.yml
├── docker/
│   ├── Dockerfile              Alpine/OpenSSH runtime; no host keys baked in
│   ├── docker-compose.yml      hardening flags, mounts, limits, log rotation
│   ├── entrypoint.sh           host-key bootstrap, key staging, sshd -t
│   ├── sshd_config             effective daemon policy
│   └── README.md               flag-by-flag runtime rationale
├── bastion/
│   ├── session-audit.sh        ForceCommand JSONL audit hook
│   └── access/                 whitelist example + validator
├── configs/
│   ├── sshd_config.example     annotated operator copy
│   ├── hardening.md            controls, lifecycle and known limits
│   └── whitelist.schema.json   JSON Schema draft 2020-12
├── terraform/                  OpenTofu OCI network, security list, compute
├── AGENT_GUIDE.md              AI agent execution playbook
├── MANUAL_PREREQS.md           operator pre-deployment checklist
├── docs/                       stage evidence and teardown audit
├── .env.example                placeholders only
├── .gitignore                  strict zero-leak boundary
└── LICENSE                     MIT, © 2026 Mostafa Kaveh
```

---

## Verification and stage status

| Stage | Scope | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Container, SSH policy, audit hook, Git boundary | ✅ complete | `docs/stage-1-verification.txt` |
| 2 | OpenTofu OCI VCN, security list, compute | ✅ validated | [`terraform/README.md`](terraform/README.md) |
| 3 | Agent playbook and operator prerequisites | ✅ complete | `docs/stage-3-verification.txt` |
| 4 | Local stack, key auth, jump and audit tests | ✅ complete | `docs/stage-4-verification.txt` |
| 5 | Live OCI deployment | ✅ complete — retry 2026-11-17 | `docs/stage-5-retry-verification.txt` |
| 6 | Earlier-attempt teardown and zero-resource verification | ✅ complete | `docs/stage-6-verification.txt` |
| 7 | Security audit, README and cost model | ✅ complete | `docs/stage-7-verification.txt` |
| 8 | Git finalization, MIT license, release, certification, final teardown | ✅ released + certified | origin/`main`, `v1.0.1`, vault 5/5 |

Local Stage 4 results: valid key login succeeded; missing, invalid and root
attempts returned SSH exit `255`; a disposable target was reached through an
explicit `ProxyCommand`; forwarding to target port 23 was denied; command and
shell sessions produced JSONL records.

OCI Stage 5 result: the first attempt created only the network plane; the
2026-11-17 retry created the A1.Flex host and passed the live SSH, audit, jump,
port-restriction and no-drift checks. Stage 6 records the earlier teardown.

CloudGuard vault: `has_iac=1`; the final `PORTABLE_CERTIFIED`/score value is
written only by the CloudGuard portability audit, not by this document.

---

## Release v1.0.1

| Item | Value |
| --- | --- |
| Repository | <https://github.com/kaveh8866/Bastion-Host-Jump-Server> |
| Branch | `main` |
| License | MIT — Copyright (c) 2026 Mostafa Kaveh |
| Tag | `v1.0.1` (certified release) |
| Earlier tag | `v1.0.0` (initial release, left in place) |
| Certification | **`PORTABLE_CERTIFIED` — 100/100 (5/5 checks), audited 2026-11-17** |

The tag is a code/documentation release. Live host evidence is recorded in
`docs/stage-5-retry-verification.txt`, the final teardown in
`docs/stage-8-teardown-verification.txt`, and the persisted CloudGuard audit is
the authoritative certification record. `v1.0.0` stays immutable at the initial
release commit; `v1.0.1` marks the certified, post-teardown state.

### CloudGuard portability audit

The official audit result for this repository:

| Check | Result |
| --- | --- |
| Zero-leak audit | ✅ passed |
| Environment scaffold | ✅ passed |
| Documentation integrity | ✅ passed |
| Git isolation | ✅ passed |
| Containerization readiness | ✅ passed |

Score: **100/100** · Status: **`PORTABLE_CERTIFIED`** · Audited: 2026-11-17

---

## Honest limits

- The live OCI host at `132.145.249.219` was reached through the operator
  tunnel and its security list exposed only TCP/22 from the operator `/32`. A
  packet-level test from a second, unauthorized public egress was not possible
  from this workstation and remains unverified. The host was destroyed on
  2026-11-18, so that external-source check can only be repeated on a new
  deployment.
- The local CIDR checks validate Terraform/whitelist policy; the live security
  list configuration was refreshed with no drift. Packet-level source-CIDR
  enforcement from an untrusted address still requires a second network.
- The cost table is a planning estimate based on published list prices and the
  configured footprint; it is not a benchmark and does not include every cloud
  line item.
- `ForceCommand` audits interactive and command sessions; `-W`/`ProxyJump`
  channels are logged by sshd but do not produce a JSONL command record.
- Docker port publishing hides the original client IP behind the bridge gateway.
- One account, one key file and one port-22 forwarding policy are intentional;
  MFA, short-lived certificates, per-target proxy policy and TLS termination are
  later work.
- The host private key is generated under gitignored `runtime/host_keys`; the
  administrator private key remains outside the repository.

---

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Mostafa Kaveh.
