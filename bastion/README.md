# Bastion source

Runtime-facing configuration and policy that is not a Docker concern.

| Path | Purpose |
| --- | --- |
| `session-audit.sh` | `ForceCommand` hook: JSONL audit record, then exec shell/command |
| `access/whitelist.example.json` | Placeholder allowlist (source CIDRs, targets, session cap) |
| `access/validate-whitelist.sh` | Validates the fields the proxy/automation contract needs |

## Access model

1. The cloud firewall admits `2222/tcp` only from the operator `/32`.
2. sshd allows only the `bastion` account and only public-key authentication.
3. The key must be present in the read-only `authorized_keys` mount.
4. Forwarding is limited to TCP/22 by `PermitOpen`; reverse tunnels are off.
5. Every interactive/command session is written to the audit JSONL before it
   runs. If the audit write fails, the session is denied.

The whitelist is the declarative expression of steps 1–4 and is validated in
Stage 1; a proxy layer in a later stage can enforce it per target. It is not a
substitute for the cloud firewall.

No private key, authorized key, host key or audit log is tracked. See
`configs/hardening.md` for the full control rationale and known limits.
