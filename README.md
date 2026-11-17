# Bastion Host / Jump Server

![Alpine](https://img.shields.io/badge/base-Alpine%203.23-0D597F?logo=alpine-linux&logoColor=white)
![OpenSSH](https://img.shields.io/badge/access-public--key%20only-4E9A06)
![Docker](https://img.shields.io/badge/Docker-read--only%20%2B%20cap__drop%20ALL-2496ED?logo=docker&logoColor=white)
![Stage](https://img.shields.io/badge/stage-6%20%C2%B7%20torn%20down-green)
![License](https://img.shields.io/badge/license-MIT-green)

A small, hardened SSH jump host for reaching private cloud resources without
exposing them. Administrators authenticate with a public key, land in an
audited session, and forward TCP/22 to the private subnet; password auth, root
login, SFTP and reverse tunnels are disabled.

**Stage 6 status — teardown complete:** the local Compose stack was stopped and
removed, and the five OCI network resources created in Stage 5 were destroyed.
A read-only OCI provider query returns zero project VCNs, instances, subnets,
security lists, gateways and route tables. Stage 5 never created compute, so no
public IP or live host exists. The repository is ready for final packaging;
certification remains scoped strictly to OCI trial credits.

---

## What Stage 1 delivers

| Area | Delivered |
| --- | --- |
| Container | Multi-arch Alpine image, OpenSSH server, tini, jq; no compiler or package cache |
| SSH policy | Public-key only, no root, no password, single allowlisted account, bounded attempts |
| Jump behaviour | TCP forwarding enabled, destination restricted to port 22, reverse tunnels and agent forwarding off |
| Auditing | `ForceCommand` hook writes structured JSONL before executing the session; fails closed |
| Runtime controls | Read-only rootfs, `cap_drop: ALL` with four sshd capabilities, `no-new-privileges`, PID/memory/CPU limits, log rotation |
| Git boundary | `.env`, host keys, authorized keys, audit logs, runtime state and OpenTofu state are ignored |
| Access policy | Versioned whitelist schema, placeholder policy and a `jq` validator |
| IaC | `terraform/` OpenTofu network + compute modules; validated, no resources applied |
| Verification | `docs/stage-1-verification.txt` |

---

## Architecture

```
operator workstation
  │  SSH key only, 2222/tcp, source /32
  ▼
[ cloud firewall / NSG ] ──► [ cloudguard-bastion ]
                                │ sshd (root master, then uid 1000)
                                │   ├─ session-audit ──► runtime/audit/sessions.jsonl
                                │   └─ PermitOpen *:22
                                ▼
                         private subnet hosts :22
```

The container is one process tree: `tini` → `sshd` → `session-audit` → shell.
Host keys and audit records live on host mounts, never in the image. A TLS
proxy / per-target policy layer is deliberately not implemented in Stage 1.

---

## Quick start

Requirements: Docker 24+ with Compose v2, an OpenSSH client, and a free
loopback port `2222`.

```bash
mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit

# Use your own key; the private key must never enter the repository.
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/bastion_admin -C bastion-admin
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion

cp -n .env.example .env
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml ps   # wait for healthy

ssh -p 2222 -i ~/.ssh/bastion_admin bastion@127.0.0.1 'id -un'
# bastion
```

The first start generates an ed25519 host key in `runtime/host_keys`. The
entrypoint copies `runtime/authorized_keys/*` into tmpfs as `root:root 0644`
so `StrictModes` also works when the source is a Windows bind mount; restart
the container after changing a key.

Use the host as a jump server:

```bash
ssh -J bastion@<bastion-host>:2222 -i ~/.ssh/bastion_admin ubuntu@10.0.0.10
```

The container publishes `127.0.0.1:2222` by default. Set
`BASTION_SSH_BIND_ADDRESS=0.0.0.0` only when the cloud firewall restricts
`2222/tcp` to the operator's `/32`.

---

## OpenTofu / OCI (Stage 2)

The infrastructure contract lives in [`terraform/`](terraform/README.md): a
10.8.0.0/16 VCN, an internet gateway, a public 10.8.1.0/24 subnet, a security
list with **one ingress rule (TCP/22 from `allowed_ssh_cidr`)** and explicit
egress for private SSH, HTTP/HTTPS and DNS, plus an Always Free eligible
`VM.Standard.A1.Flex` instance running Ubuntu 24.04.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit tenancy, compartment, operator /32 and public key
tofu init && tofu fmt -recursive -check && tofu validate
```

The host SSH daemon owns TCP/22; the Compose listener remains loopback-bound on
2222 until a deployment stage deliberately changes the mapping. No OCI resource
was created in Stage 2, and `terraform.tfvars`/state stay local and ignored.
AWS/GCP mapping notes are in the module comments and the Terraform README.

---

## Agent and operator documentation (Stage 3)

- [`AGENT_GUIDE.md`](AGENT_GUIDE.md) — execution playbook for AI coding agents:
  local bring-up, key lifecycle, firewall checks, audit queries, active-session
  inspection, negative auth tests, troubleshooting and change discipline.
- [`MANUAL_PREREQS.md`](MANUAL_PREREQS.md) — the human operator's pre-deployment
  checklist: OCI API profile, SSH key, management `/32`, `.env`, Terraform
  inputs, local smoke test, deployment-day sequence and teardown.

Both state the same certification boundary: the container and IaC are
cloud-agnostic with AWS/GCP mappings, but **final production verification and
testing certification are performed strictly on OCI using trial credits**.
AWS and GCP are ports, not certified targets. Stage 3 itself is documentation
and local validation; no live deployment is claimed.

---

## Local verification (Stage 4)

| Check | Result |
| --- | --- |
| Compose build/up | image built; `cg-bastion` healthy on `127.0.0.1:2222` |
| Startup | `sshd` listening on `0.0.0.0:2222`; `ForceCommand` hooked |
| Valid key | command exit `0`, output `bastion` / `stage4-ok` |
| Missing key | refused, exit `255` |
| Invalid key | refused, exit `255` |
| Root with valid key | refused, exit `255` |
| End-to-end jump | disposable target reached through the bastion, exit `0` |
| Disallowed port | forwarding to target port 23 denied, exit `255` |
| Audit | command and shell records present with user, source and timestamp |
| Leak scan | no private-key block in logs, tracked files or audit records |
| CIDR policy | Terraform rejects `0.0.0.0/0`; whitelist rejects world-open and malformed CIDRs |

Local CIDR checks validate policy. The OCI security-list packet filter is not
running locally, so an external source-CIDR test belongs to the live stage.
Raw transcript: [`docs/stage-4-verification.txt`](docs/stage-4-verification.txt).

---

## OCI deployment attempt (Stage 5 — blocked)

| Item | Result |
| --- | --- |
| OpenTofu init/validate/test | pass; 0 tests |
| Plan | 6 to add; one TCP/22 ingress from operator `/32` |
| Network apply | VCN, IGW, route table, security list, subnet created |
| A1.Flex AD-1/2/3 | `500-InternalError, Out of host capacity` |
| E2.1.Micro AD-1/2 | `400-LimitExceeded, The limit for this tenancy has been exceeded` |
| Compute instance / public IP | **not created / none** |
| Remote deployment and live checks | **not run** |

No `feat(deploy)` success is claimed. Stage 5's network resources were later
destroyed in Stage 6; the Stage 5 evidence records the original blocker.
[`docs/stage-5-verification.txt`](docs/stage-5-verification.txt).

---

## Teardown (Stage 6 — complete)

| Check | Result |
| --- | --- |
| Local `docker compose down` | `cg-bastion` removed; Compose network removed |
| Pre-destroy state | five OCI network resources; no compute instance |
| `tofu destroy -auto-approve` | **5 destroyed**, exit `0` |
| Post-destroy state | empty; no outputs |
| OCI project inventory | VCNs, instances, subnets, security lists, gateways, route tables all `[]` |
| Remote container | not applicable — Stage 5 never created a host |

Zero-resource verification used read-only OCI provider data sources, not a
visual console check. Unrelated tenancy resources were not touched. Evidence:
[`docs/stage-6-verification.txt`](docs/stage-6-verification.txt).

---

## Access policy

`bastion/access/whitelist.example.json` describes the administrative identity,
its source CIDR and the private targets it may reach. The contract is in
`configs/whitelist.schema.json`; validate a policy with:

```bash
./bastion/access/validate-whitelist.sh bastion/access/whitelist.example.json
# whitelist valid: ...
```

The whitelist is a declarative policy input. **It is not a packet filter**:
source CIDRs must be enforced by the OCI security list/NSG, and sshd enforces
the account (`AllowUsers bastion`), key and port-22 forwarding limits. A proxy
layer in a later stage can consume the same schema for per-target enforcement.

---

## Layout

```
.
├── docker/
│   ├── Dockerfile              multi-arch Alpine runtime, no host keys baked in
│   ├── docker-compose.yml      hardening flags, mounts, limits, log rotation
│   ├── entrypoint.sh           host-key bootstrap, key staging, sshd -t
│   ├── sshd_config             effective daemon policy
│   └── README.md               flag-by-flag runtime rationale
├── bastion/
│   ├── session-audit.sh        ForceCommand JSONL audit hook
│   ├── access/                 whitelist example + validator
│   └── README.md
├── configs/
│   ├── sshd_config.example     annotated operator copy
│   ├── hardening.md            controls, lifecycle and known limits
│   ├── whitelist.schema.json   JSON Schema draft 2020-12
│   └── README.md
├── terraform/                  OpenTofu OCI VCN, security list and compute modules
├── AGENT_GUIDE.md              AI agent execution playbook (Stage 3)
├── MANUAL_PREREQS.md           operator pre-deployment checklist (Stage 3)
├── docs/                       stage evidence
├── .env.example                placeholders only
├── .gitignore                  strict zero-leak boundary
└── LICENSE                     MIT, © 2026 Mostafa Kaveh
```

---

## Security posture (verified)

| Control | Observed |
| --- | --- |
| Root filesystem | `ReadonlyRootfs=true` |
| Capabilities | `CapDrop=[ALL]`, retained `CHOWN`, `SETGID`, `SETUID`, `SYS_CHROOT` |
| Privilege escalation | `no-new-privileges:true` |
| PIDs / memory / CPU | 128 / 256 MiB / 0.50 CPU |
| Root login | `permitrootlogin no` |
| Passwords | `passwordauthentication no`; keyboard-interactive off |
| Public keys | `pubkeyauthentication yes`, `authorizedkeysfile /run/authorized_keys/%u` |
| Account allowlist | `allowusers bastion` |
| Forwarding | `allowtcpforwarding yes`, `permitopen *:22`, reverse tunnels off |
| Session audit | `forcecommand /usr/local/bin/session-audit`, JSONL record written before exec |
| Host keys | Generated on first start into a mount; never in the image |
| Logs | `json-file`, 10 MiB × 3 |

A command session produces:

```json
{"timestamp":"2026-11-17T19:54:42Z","user":"bastion","source":"172.24.0.1","action":"command","command":"id -un; echo bastion-ok"}
```

---

## Verification (Stage 1)

| Check | Result |
| --- | --- |
| `docker compose config -q` | valid |
| Image build | `cloudguard/bastion:local` built successfully |
| Container | `cg-bastion` — **healthy**, `127.0.0.1:2222->2222/tcp` |
| Key-only session | `id -un` → `bastion`; command returned `bastion-ok` |
| Password login | refused, exit `255` |
| Root login with a valid key | refused, exit `255` |
| Audit hook | one JSON object written for the session, including source and command |
| Effective sshd config | `sshd -T` exit `0`, 83 lines; key directives confirmed |
| White-list validator | `whitelist valid` |
| Git boundary | `.env`, host keys, audit records and test key all ignored |
| Live cloud | **not executed** — no OCI resource exists |

TCP forwarding was exercised: the channel reached the target-connect stage and
was refused because the test container had no service on port 22. This proves
the forwarding path is enabled but is **not** an end-to-end proxy test; that
belongs to the live stage with a real private target.

Raw transcript: [`docs/stage-1-verification.txt`](docs/stage-1-verification.txt).

---

## Roadmap

| Stage | Scope | Status |
| --- | --- | --- |
| 1 | Scaffold, container, SSH/audit policy, zero-leak boundary, local verification | ✅ complete |
| 2 | OpenTofu OCI VCN, security list, compute and bastion host | ✅ validated |
| 3 | Agent playbook, operator prerequisites, OCI certification scope | ✅ complete |
| 4 | Local stack, SSH auth/jump and session-audit verification | ✅ complete |
| 5 | Live OCI deployment, host bootstrap, real jump/audit test | ⚠️ blocked — capacity/quota |
| 6 | Clean teardown, zero-resource verification, staging | ✅ complete |
| 7 | TLS proxy layer, per-target enforcement, packaging | not started |
| 8 | Final documentation, provider verification, CloudGuard certification | not started |

CloudGuard vault status after Stage 6: **indexed**, `has_iac=1` —
`PORTABLE_CERTIFIED` remains pending a successful live verification.

---

## Honest limits

- Stage 4 and earlier were local only. Stage 5 created the OCI network, then
  Stage 6 destroyed it; no compute instance or public host was ever created.
  The live jump and packet-level CIDR checks remain unverified.
- The local CIDR test proves Terraform and whitelist policy rejection, not OCI
  security-list packet enforcement; that remains a live-stage check.
- The A1 capacity and E2 tenancy-limit errors are recorded as blockers; no paid
  shape was substituted and no unrelated tenancy resource was touched.
- The local Compose container is stopped; its gitignored runtime keys and audit
  records are retained for reproducibility but are not cloud resources.
- The host private key is generated under `runtime/host_keys` and is gitignored;
  the administrator private key remains outside the repository in `~/.ssh`.
- sshd must run as the root master; the container narrows capabilities but does
  not run the daemon as an unprivileged user. Session processes run as uid 1000.
- `ForceCommand` audits interactive and command sessions. OpenSSH handles
  `-W`/`ProxyJump` forwarding before that hook, so those channels are visible in
  sshd's `VERBOSE` log but do not produce a JSONL command record.
- There is one account (`bastion`), one key file and one port-22 forwarding
  policy. MFA, short-lived certificates, per-target proxy policy and TLS
  termination are later work.
- The account password field is cleared (`passwd -d`) so sshd does not treat it
  as locked; password and keyboard-interactive authentication remain disabled.
- Changing an authorized key requires a container restart to re-stage it.
- No upstream CI workflow or release tag exists yet; this stage is the scaffold.

---

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Mostafa Kaveh.
