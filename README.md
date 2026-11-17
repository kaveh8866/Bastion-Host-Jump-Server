# Bastion Host / Jump Server

![Alpine](https://img.shields.io/badge/base-Alpine%203.23-0D597F?logo=alpine-linux&logoColor=white)
![OpenSSH](https://img.shields.io/badge/access-public--key%20only-4E9A06)
![Docker](https://img.shields.io/badge/Docker-read--only%20%2B%20cap__drop%20ALL-2496ED?logo=docker&logoColor=white)
![Stage](https://img.shields.io/badge/stage-1%20%C2%B7%20scaffolded-blue)
![License](https://img.shields.io/badge/license-MIT-green)

A small, hardened SSH jump host for reaching private cloud resources without
exposing them. Administrators authenticate with a public key, land in an
audited session, and forward TCP/22 to the private subnet; password auth, root
login, SFTP and reverse tunnels are disabled.

**Stage 1 status:** scaffold and local verification complete. The image builds,
the container is healthy, key-only login works, and every interactive command
is written to a JSONL audit trail. No OCI resource has been created or applied;
`terraform/` is reserved for Stage 2, and TLS proxying is a later stage.

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
| IaC | `terraform/` reserved with the Stage 2 resource contract; no resources applied |
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
├── terraform/                  reserved for Stage 2 (no resources yet)
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
| 2 | OpenTofu OCI VCN, security list, compute and reserved endpoint | reserved |
| 3 | Live deployment on OCI, host bootstrap, real jump/audit test | not started |
| 4 | TLS proxy layer, per-target enforcement, central audit shipping | not started |
| 5 | Packaging, agent/operator guides, cost model, zero-leak audit | not started |
| 6 | Teardown, provider verification, CloudGuard certification | not started |

CloudGuard vault status after Stage 1: **indexed** — `PORTABLE_CERTIFIED`
remains pending the later verification stages.

---

## Honest limits

- Stage 1 is local only. Nothing in this repository creates or verifies a cloud
  resource, and no live deployment is claimed.
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
