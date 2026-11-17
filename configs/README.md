# Configuration inventory

| File | Purpose |
| --- | --- |
| `sshd_config.example` | Annotated operator copy of the daemon policy; runtime copy is `docker/sshd_config` |
| `hardening.md` | Authentication, forwarding, auditing and container posture rationale |
| `whitelist.schema.json` | JSON Schema (draft 2020-12) for administrative users, source CIDRs and targets |
| `../bastion/access/whitelist.example.json` | Placeholder policy that validates against the schema |
| `../bastion/access/validate-whitelist.sh` | `jq` validator for the fields automation depends on |

No private keys, authorized keys, host keys or audit records belong here.
Runtime material is written under `runtime/`, which is gitignored.
