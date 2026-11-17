# Agent Guide — Bastion Host / Jump Server

An execution playbook for AI coding agents (Cursor, Claude Code, Windsurf,
Codex) working on this repository. It assumes no prior context: commands are
written to be run from the repository root, and expected results are stated so
"it started" is never confused with "it works".

**Scope:** build, run, key-manage, audit and inspect the hardened SSH jump host.
Infrastructure is validated OpenTofu in `terraform/`; provisioning belongs to a
dedicated deployment stage.

**Certification scope:** the container and IaC are cloud-agnostic, with AWS and
GCP mappings documented. **Final production verification and testing
certification are performed strictly on Oracle Cloud Infrastructure (OCI) using
trial credits.** AWS and GCP are ports, not certified targets. As of Stage 3 no
cloud deployment has run, so no live host is claimed.

---

## 0. Non-negotiables

These hold for every action, including exploratory ones.

1. **Never print, log or commit a private key, host key or credential.** Public
   keys and key fingerprints are public; private material never is.
2. **Never copy a secret into a tracked file, test fixture, doc or commit.**
   `.env`, `runtime/`, host keys, authorized keys, audit records and
   `terraform.tfvars` are gitignored — verify with `git check-ignore -v`.
3. **Keep the container loopback-bound by default.** Do not set
   `BASTION_SSH_BIND_ADDRESS=0.0.0.0` unless a cloud firewall rule restricts
   2222/tcp to a single management CIDR. The Terraform perimeter only admits 22.
4. **`tofu apply` and `tofu destroy` are deployment-stage actions.** Do not run
   them while editing code or docs; they need an explicit operator request.
5. **Do not weaken a security control to make a test pass.** Fix the copy,
   permission, mount or config instead. `StrictModes`, `cap_drop`, read-only
   rootfs and the security list are not optional.
6. **Report unverified work as unverified.** A passing build or `sshd -T` does
   not prove a live private-target jump; Stage 3 makes no cloud claim.

---

## 1. Repository map

| Path | What it is |
| --- | --- |
| `docker/Dockerfile` | Multi-arch Alpine + OpenSSH image; no host keys baked in |
| `docker/docker-compose.yml` | Read-only rootfs, capability drop, limits, log rotation, mounts |
| `docker/sshd_config` | Effective daemon policy: key-only, no root, TCP/22 forwarding |
| `docker/entrypoint.sh` | Host-key bootstrap, tmpfs key staging, `sshd -t` |
| `bastion/session-audit.sh` | `ForceCommand` hook: JSONL record, then exec shell/command |
| `bastion/access/` | Whitelist example and `jq` validator |
| `configs/` | Annotated sshd policy, hardening rationale, whitelist schema |
| `terraform/` | OCI VCN, security list, subnet and A1.Flex compute; validated, not applied |
| `runtime/` | Ignored host keys, authorized keys and audit JSONL |
| `docs/` | Stage evidence transcripts |

Ports: **2222** inside the container; host publication is
`127.0.0.1:2222` by default. Container: `cg-bastion`. Image:
`cloudguard/bastion:local`. Account: `bastion` (uid 1000).

The OCI host's own SSH daemon owns TCP/22. The Terraform security list admits
only 22, not 2222. Keep that distinction when debugging reachability.

---

## 2. Prerequisites check

```bash
docker --version                 # 24+
docker compose version           # v2+
ssh -V                           # OpenSSH client
git --version
```

OpenTofu is not on `PATH` in this workspace; use the project binary:

```bash
TOFU=/c/Users/Kaveh/Desktop/CloudGuard/.cloudguard/tools/tofu/tofu.exe
"$TOFU" version                  # OpenTofu v1.13.9
```

On Windows use Git Bash. Docker bind mounts may rewrite paths; use
`MSYS_NO_PATHCONV=1` only where a mount is being misinterpreted. Use
project-relative paths for temporary files — native Windows binaries do not
share `/tmp` with Git Bash.

`jq` is inside the bastion image. On the host, prefer
`docker exec cg-bastion jq ...` rather than assuming a host `jq`.

---

## 3. Fast path — local bastion in under two minutes

```bash
cd projects/08-bastion-host-jump-server
mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit

# Generate an operator key once. The private half stays in ~/.ssh.
ssh-keygen -t ed25519 -a 100 -C "bastion-admin" -f ~/.ssh/bastion_admin
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion
chmod 0644 runtime/authorized_keys/bastion

cp -n .env.example .env
chmod 600 .env

docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml ps
# wait until STATUS contains "(healthy)"
```

Expected state: `cg-bastion` is healthy and bound to `127.0.0.1:2222`.

Verify a real key-only session:

```bash
ssh -p 2222 -i ~/.ssh/bastion_admin \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  bastion@127.0.0.1 'id -un; echo bastion-ok'
```

Expected:

```
bastion
bastion-ok
```

If it fails, read the first useful server error before retrying:

```bash
docker logs --tail 50 cg-bastion
```

Common causes are an unstaged key, a stale container after a key change, or a
file that is not readable by sshd's privilege-separated child. Do not disable
`StrictModes` to work around it.

---

## 4. Authorized key lifecycle

The host mount is the source of truth. The entrypoint copies every file in
`runtime/authorized_keys/` into `/run/authorized_keys/` as `root:root 0644`
because sshd's unprivileged child must read it, and Windows bind mounts report
world-writable permissions that `StrictModes` rejects.

Add or rotate a key:

```bash
# Replace the file with exactly one public key line.
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion
chmod 0644 runtime/authorized_keys/bastion

# The entrypoint stages keys at container start, so restart after a change.
docker compose --env-file .env -f docker/docker-compose.yml restart bastion
```

Checks:

```bash
docker exec cg-bastion sh -c 'ls -l /run/authorized_keys; cat /run/authorized_keys/bastion'
docker exec cg-bastion ssh-keygen -lf /run/authorized_keys/bastion
```

Rules:

- Never put a private key under `runtime/`, even though the directory is
  ignored. `runtime/authorized_keys/` is for public keys only.
- `AllowUsers bastion` is static in `docker/sshd_config`; adding a second
  account requires a config change, a matching key file, and a rebuild.
- If a key is compromised, replace the file and restart; no image rebuild is
  needed. Audit records remain on the host mount.

---

## 5. Firewall and network restrictions

### Local

The Compose default is loopback-only:

```bash
docker inspect cg-bastion --format '{{json .HostConfig.PortBindings}}'
# {"2222/tcp":[{"HostIp":"127.0.0.1","HostPort":"2222"}]}
```

Do not change `BASTION_SSH_BIND_ADDRESS` to `0.0.0.0` just to test from another
machine. Use an SSH tunnel or a local port-forward; a publicly bound listener
without a cloud firewall rule is an exposure.

### OCI perimeter

`terraform/modules/network/main.tf` creates exactly one ingress rule:

```
TCP/22 from allowed_ssh_cidr
```

No 80/443, no ICMP, no management ports. Egress is explicit: TCP/22 to
`private_target_cidr`, TCP/80/443 to the internet for packages and images, and
UDP/53 for DNS. `allowed_ssh_cidr` validation rejects `0.0.0.0/0` and `::/0`.

Check the effective host listener and the security-list inventory separately:

```bash
docker compose --env-file .env -f docker/docker-compose.yml ps
docker port cg-bastion
ss -ltnp | grep ':2222' || true          # Linux host
```

On Windows PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 2222 -ErrorAction SilentlyContinue
```

Cloud firewall changes are operator actions in the OCI console or a reviewed
Terraform change — never an ad-hoc `0.0.0.0/0` rule.

---

## 6. Verify session auditing

The `ForceCommand` hook writes one JSON object per session before executing it.
It fails closed: an unwritable audit directory denies the session.

Local file:

```bash
tail -n 5 runtime/audit/sessions.jsonl
```

Inside the container (host mount at `/var/log/bastion`):

```bash
docker exec cg-bastion tail -n 5 /var/log/bastion/sessions.jsonl
docker exec cg-bastion jq -r \
  'select(.action=="command") | [.timestamp,.user,.source,.command] | @tsv' \
  /var/log/bastion/sessions.jsonl
```

Expected record after the fast-path command:

```json
{"timestamp":"2026-11-17T19:54:42Z","user":"bastion","source":"172.24.0.1","action":"command","command":"id -un; echo bastion-ok"}
```

Notes:

- The source may be the Docker bridge gateway (`172.24.0.1`) because port
  publishing NATs the connection. Do not treat it as the real client address
  unless the stack uses host networking or a proxy that forwards the peer.
- `ForceCommand` covers interactive and command sessions. OpenSSH handles
  `-W`/`ProxyJump` forwarding before that hook, so those channels appear in
  sshd's `VERBOSE` log rather than as JSONL command records.
- Protect the host directory: audit records contain command text and may
  contain sensitive arguments. Ship them to central storage and rotate them;
  never commit them.

---

## 7. Inspect security logs and active connections

Authentication and session metadata:

```bash
docker logs --tail 80 cg-bastion
docker logs --since 15m cg-bastion 2>&1 | \
  grep -E 'Accepted publickey|Failed publickey|Invalid user|Starting session|Disconnected|Connection closed'
```

`LogLevel VERBOSE` records key fingerprints, source address and session
transitions. Fingerprints are public identifiers; never log private key bytes.

Active processes and connections:

```bash
docker top cg-bastion
docker exec cg-bastion ps
ss -tnp | grep ':2222' || true          # Linux host
```

On Windows, use `Get-NetTCPConnection -LocalPort 2222`. `docker top` is the
portable way to see sshd and session children inside the container.

Health and restart history:

```bash
docker inspect cg-bastion --format \
  'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restarts={{.RestartCount}}'
docker compose --env-file .env -f docker/docker-compose.yml logs --tail 100
```

Do not paste raw logs into a ticket if they contain command arguments that may
be sensitive. Audit records and command lines are data, not credentials, but
they still deserve handling discipline.

---

## 8. Verification commands

Run these after any change to the image, config, audit hook or docs:

```bash
cd projects/08-bastion-host-jump-server

# Compose syntax and image build
docker compose --env-file .env.example -f docker/docker-compose.yml config -q
docker compose --env-file .env.example -f docker/docker-compose.yml build

# Shell syntax
bash -n docker/entrypoint.sh bastion/session-audit.sh bastion/access/validate-whitelist.sh

# Daemon policy (inside a healthy container)
docker exec cg-bastion /usr/sbin/sshd -T -f /etc/ssh/sshd_config | \
  grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|permitopen|forcecommand|authorizedkeysfile)'

# Negative authentication: both must be non-zero
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o BatchMode=yes bastion@127.0.0.1 true; echo "password_exit=$?"
ssh -p 2222 -i ~/.ssh/bastion_admin -o IdentitiesOnly=yes \
  -o BatchMode=yes root@127.0.0.1 true; echo "root_exit=$?"

# Whitelist policy
./bastion/access/validate-whitelist.sh bastion/access/whitelist.example.json

# IaC
cd terraform
TOFU=/c/Users/Kaveh/Desktop/CloudGuard/.cloudguard/tools/tofu/tofu.exe
"$TOFU" fmt -recursive -check
"$TOFU" validate
```

Run `tofu plan` only with real operator credentials and an approved deployment
stage. Never `tofu apply` while working on documentation.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Permission denied (publickey)` | Key not staged, stale container, or key file unreadable | Check `docker logs`; confirm file; `restart bastion`; do not disable StrictModes |
| `User bastion not allowed because account is locked` | Image account not unlocked | Rebuild from current Dockerfile (`passwd -d bastion`); do not change auth to password |
| `Could not open ... authorized keys: Permission denied` | staged file mode/owner wrong | Inspect `/run/authorized_keys`; rebuild current entrypoint (root:root 0644) |
| Port 2222 already allocated | Local SSH or another stack | Change `BASTION_SSH_PORT` in `.env`, then restart |
| Host key changed warning | `runtime/` deleted or host key rotated | Remove the stale `known_hosts` entry after confirming the change |
| Container is `unhealthy` | sshd not listening or config invalid | `docker logs`; run `sshd -t`; fix config, do not bypass healthcheck |
| Audit hook denies session | audit mount unwritable | Fix host directory ownership/mode; the hook is intentionally fail-closed |
| `tofu validate` provider mismatch | Module missing `oracle/oci` source | Keep the `versions.tf` declarations in both modules |
| Audit `source` is `172.24.0.1` | Docker port NAT | Expected with bridge networking; use host networking/proxy for true client IP |

---

## 10. Change discipline

1. Make the smallest change; never widen the security list, auth methods or
   container capabilities to make a test pass.
2. Run the verification block in section 8.
3. Check the Git boundary:
   ```bash
   git status --porcelain
   git check-ignore -v runtime/host_keys runtime/audit .env terraform/terraform.tfvars
   git ls-files | grep -E '(^|/)(\.env$|runtime/|.*\.tfstate|terraform\.tfvars$)' || true
   ```
4. Record actual command output in `docs/stage-N-verification.txt`; label
   anything not executed.
5. Commit with a semantic message and no credential, OCID or private key.
6. Do not push or deploy until the project lifecycle stage explicitly requires
   it and the operator approves.

---

## 11. Certification scope

- The container and OpenTofu modules are **Cloud-Agnostic** (supporting AWS,
  GCP and OCI). AWS (VPC, security group, EC2, user-data) and GCP (VPC,
  firewall rule, Compute Engine, metadata startup script) mappings are
  documented in `terraform/README.md` and the module comments.
- **Final production verification and testing certification are performed
  strictly on Oracle Cloud Infrastructure (OCI) using trial credits.** AWS and
  GCP are ports, not certified targets.
- In short: final production verification and testing certification are
  performed strictly on OCI using trial credits; no AWS or GCP certification
  run is claimed.
- As of Stage 3, **no OCI resource has been planned, applied or destroyed**;
  Stage 1 was local, Stage 2 was `tofu validate`, and this stage is
  documentation. No live host, live jump or production certification is
  claimed. Those claims require the deployment stage's recorded evidence.
- The current local verification covers: image build, healthy container,
  key-only login, password/root refusal, JSONL audit write, whitelist
  validation and the inspected hardening flags.
