# Bastion Host / Jump Server — hardening model

This document describes what the Stage 1 scaffold actually enforces. It does
not replace a live verification; the evidence for this stage is in
`docs/stage-1-verification.txt`.

## Authentication

| Control | Setting | Effect |
| --- | --- | --- |
| Root login | `PermitRootLogin no` | No direct administrative shell as root |
| Password auth | `PasswordAuthentication no` | Guessing a password is impossible |
| Keyboard interactive | `KbdInteractiveAuthentication no` | No PAM/challenge fallback |
| Public keys only | `AuthenticationMethods publickey` | Every session is key-backed |
| Account allowlist | `AllowUsers bastion` | No other local account can authenticate |
| Key source | `/run/authorized_keys/%u` | Entrypoint copies from the read-only mount into tmpfs with root:root 0644, so `StrictModes` holds on Windows mounts |
| Attempts | `MaxAuthTries 3` | Bounded authentication attempts |
| Grace period | `LoginGraceTime 20` | Unauthenticated sockets are short-lived |

Put exactly one public key line in `runtime/authorized_keys/bastion`. The entrypoint
copies it into tmpfs as root:root mode `0644` on start, which keeps `StrictModes`
effective even when the source is a Windows bind mount; public keys are not
secrets, and sshd's privilege-separated child must be able to read them. Key
changes require a container restart. The private key stays on the operator's
workstation.

## Forwarding

`AllowTcpForwarding yes` is what makes the host a jump server. `PermitOpen *:22`
restricts forwarding to SSH on the destination; `PermitListen none`,
`GatewayPorts no`, and `PermitTunnel no` prevent reverse tunnels and VPN-style
exposure. Narrow `PermitOpen` to the exact target hosts once the private
topology is known — the sample file is intentionally broad within port 22.

```bash
ssh -J bastion@<bastion-host>:2222 -i ~/.ssh/bastion_admin ubuntu@10.0.0.10
```

## Session auditing

`ForceCommand /usr/local/bin/session-audit` writes one JSON object per
interactive or command session to `runtime/audit/sessions.jsonl`:

```json
{"timestamp":"2026-11-17T12:00:00Z","user":"bastion","source":"203.0.113.10","action":"command","command":"uptime"}
```

The hook fails closed: if the audit record cannot be written, the session is
denied. The audit directory is a host mount and is ignored by Git. Command text
can contain sensitive arguments, so protect the host directory and ship records
to the central log store before rotating them.

**Known limitation:** OpenSSH handles `-W`/`ProxyJump` TCP forwarding before
`ForceCommand`, so those channels do not produce a JSONL command record. Their
connection metadata is still emitted by `LogLevel VERBOSE` to the container log.
A future stage can add per-channel auditing at the proxy layer.

## Container posture

| Control | Runtime value |
| --- | --- |
| Root filesystem | `read_only: true` |
| Capabilities | `cap_drop: ALL`, then `CHOWN`, `SETGID`, `SETUID`, `SYS_CHROOT` |
| Privilege escalation | `no-new-privileges:true` |
| PIDs | 128 |
| Memory / CPU | 256 MiB / 0.50 CPU |
| `/run`, `/tmp` | size-bounded, `nosuid`, `nodev`; `/tmp` also `noexec` |
| Logs | `json-file`, 10 MiB × 3 |
| Host keys | generated on first start in `runtime/host_keys`, never baked in |
| Audit | append-only JSONL in `runtime/audit` |

sshd must start as root to separate privileges and `setuid` into the session
account. The capability set is reduced to the four operations that transition
requires; no application process runs as root.

## Network exposure

The Compose default publishes `127.0.0.1:2222`. A real bastion binds
`0.0.0.0` **only** when the cloud firewall admits `2222/tcp` from the
operator's `/32`. The access whitelist schema is a policy input for the
operator and the future proxy layer; it is not itself a packet filter. Enforce
source CIDRs in the OCI security list/NSG, never by editing `sshd_config` alone.

## Key and host-key lifecycle

- Generate the operator key with `ssh-keygen -t ed25519 -a 100`.
- Add the public key to `runtime/authorized_keys/bastion`; never commit it.
- Host keys are generated once and persist in `runtime/host_keys`. Back them up
  if clients pin fingerprints; deleting the directory changes the fingerprint.
- Rotate a compromised operator key by replacing the authorized-keys file and
  restarting the container; no image rebuild is needed.

## Deliberately out of scope for Stage 1

- OCI network, compute and firewall resources (`terraform/` is reserved).
- TLS proxying and per-target policy enforcement at a proxy layer.
- MFA, short-lived certificates and central audit shipping.
- Any live deployment or claim of production certification.
