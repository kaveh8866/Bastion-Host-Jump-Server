# Manual Prerequisites — Bastion Host / Jump Server

A checklist for the human operator before running any deployment script. Work
top to bottom: each phase ends with a verification command whose expected
result is stated, so "done" never means "looks done".

**What you end up with:** one OCI compute instance running the hardened bastion
container, reachable only from your management CIDR on TCP/22, with host keys
and JSONL session records persisted on the host.

**Certification scope:** the container and IaC are cloud-agnostic (AWS and GCP
mappings are documented in `terraform/README.md`), but **final production
verification and testing certification are performed strictly on Oracle Cloud
Infrastructure (OCI) using trial credits**. AWS and GCP are ports, not certified
targets. As of Stage 3, no cloud deployment has executed; this checklist
prepares one and does not claim it happened.

---

## Phase 0 — Decisions before touching the cloud

| Decision | Default | Why it matters |
| --- | --- | --- |
| Region | `eu-frankfurt-1` | A1 capacity differs by region and AD; changing it later means a new VCN |
| Compartment | your project compartment | Scopes every resource Terraform creates; never reuse an unrelated compartment |
| Shape | `VM.Standard.A1.Flex`, 1 OCPU / 6 GB | Always Free ARM; `VM.Standard.E2.1.Micro` is the trial/free fallback |
| Management CIDR | your public `/32` on TCP/22 | The only ingress the security list permits |
| Public listener | host SSH on 22; container on loopback 2222 | The Terraform perimeter does **not** admit 2222 |
| Audit retention | host `runtime/audit`, shipped off-host | Records contain command text and may be sensitive |
| Budget | alert at $1 or the lowest useful threshold | Catches accidental paid resources; the stack is free-tier by design |

- [ ] I know which compartment and region this project owns.
- [ ] I have a budget alert configured.
- [ ] I accept that the only inbound cloud port is TCP/22 from my CIDR.

---

## Phase 1 — Workstation tools

| Tool | Minimum | Verify |
| --- | --- | --- |
| Git | 2.30 | `git --version` |
| Docker Engine or Desktop | 24 with Compose v2 | `docker compose version` |
| OpenSSH client | any current release | `ssh -V` |
| OpenTofu | 1.6+ (workspace ships 1.13.9) | `"$TOFU" version` |
| curl | any | `curl --version` |
| jq (optional on host) | any | `jq --version` (image has jq regardless) |

OpenTofu is not on `PATH` in this workspace:

```bash
TOFU=/c/Users/Kaveh/Desktop/CloudGuard/.cloudguard/tools/tofu/tofu.exe
"$TOFU" version     # OpenTofu v1.13.9
```

- [ ] Every command succeeds.
- [ ] On Windows, I am using Git Bash for the commands below.
- [ ] I use project-relative paths for temporary files.

---

## Phase 2 — OCI account, credentials and permissions

### 2.1 Account

- [ ] OCI tenancy with Always Free eligibility or active **trial credits**.
- [ ] A dedicated compartment for this project; note its OCID.
- [ ] A budget alert at a low threshold.
- [ ] Free-tier capacity in the target availability domain. If A1.Flex returns
      "Out of host capacity" in every AD, use `VM.Standard.E2.1.Micro`; the
      container is capped at 256 MiB and fits.
- [ ] An IAM policy allowing your user to manage VCNs, subnets, security lists
      and instances in that compartment.

### 2.2 API signing key

Terraform authenticates with the OCI CLI profile, not with a password.

1. OCI Console → Identity & Security → Users → your user → **API keys** → Add
   API key → generate or paste a public key.
2. Download the private key **once**; it cannot be downloaded again.
3. Store it outside every repository, for example `~/.oci/oci_api_key.pem`,
   mode `0600`.
4. Create or update `~/.oci/config`:

```ini
[DEFAULT]
user=ocid1.user.oc1..your-user-placeholder
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..your-tenancy-placeholder
region=eu-frankfurt-1
key_file=~/.oci/oci_api_key.pem
```

Alternatively, run `oci setup config` if the OCI CLI is installed; it writes the
same profile and key.

- [ ] `ls -l ~/.oci/oci_api_key.pem` shows mode `600`.
- [ ] `~/.oci/config` is outside this repository and will never be tracked.
- [ ] I can read the tenancy OCID and compartment OCID from the console.
- [ ] I have not printed, pasted or committed the private key.

The Terraform variables `user_ocid`, `fingerprint` and `private_key_path` exist
for CI runners that materialise a key at runtime. Prefer the profile locally.

---

## Phase 3 — Administrator SSH key and management CIDR

### 3.1 SSH key pair

```bash
ssh-keygen -t ed25519 -a 100 -C "cloudguard-bastion" -f ~/.ssh/bastion_admin
chmod 600 ~/.ssh/bastion_admin
chmod 644 ~/.ssh/bastion_admin.pub
```

- [ ] `cat ~/.ssh/bastion_admin.pub` starts with `ssh-ed25519 `.
- [ ] The private key is in `~/.ssh`, never in `runtime/` or `terraform/`.
- [ ] I can use an ssh-agent if the key has a passphrase.

Only the **public key content** goes into `terraform.tfvars`; the runtime key
file goes into `runtime/authorized_keys/bastion` on the host. The Terraform
validation rejects anything that is not an OpenSSH public key.

### 3.2 Management CIDR

```bash
curl -s https://api.ipify.org
```

- [ ] I have my current public IPv4 address.
- [ ] I will use it as a `/32` (for example `203.0.113.10/32`), or a VPN /
      management range if my address changes.
- [ ] I will never use `0.0.0.0/0`; the Terraform variable validation refuses it.
- [ ] I understand that IPv6 is outside this VCN/security-list design.

---

## Phase 4 — Clone, runtime config and Git boundary

> **Publication note:** Stages 1–3 are local commits. The remote is linked but
> has not received the scaffold yet. Use the local workspace path
> (`projects/08-bastion-host-jump-server`) until the release stage publishes
> `main`, then the clone command below applies unchanged.

```bash
git clone https://github.com/kaveh8866/Bastion-Host-Jump-Server.git
cd Bastion-Host-Jump-Server

mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit
cp -n .env.example .env
chmod 600 .env
```

- [ ] `git check-ignore -v .env` prints a matching rule.
- [ ] `git status --porcelain` does not list `.env` or `runtime/`.
- [ ] No private key exists anywhere under the repository.

`.env` values that matter:

| Key | Default | Guidance |
| --- | --- | --- |
| `BASTION_SSH_BIND_ADDRESS` | `127.0.0.1` | Keep loopback on a host unless the cloud firewall explicitly admits the mapped port |
| `BASTION_SSH_PORT` | `2222` | Host-side container port; the OCI security list does not admit it |
| `BASTION_HOST_KEY_DIR` | `../runtime/host_keys` | Relative to `docker/docker-compose.yml`; gitignored |
| `BASTION_AUTHORIZED_KEYS_DIR` | `../runtime/authorized_keys` | Public keys only; gitignored |
| `BASTION_AUDIT_DIR` | `../runtime/audit` | JSONL records; gitignored |
| `BASTION_ADMIN_PUBLIC_KEY_PATH` | `../runtime/authorized_keys/bastion` | Host path to the staged public key |
| `BASTION_ADMIN_PUBLIC_KEY` | placeholder | Informational; the real public key goes in the file above |
| `BASTION_ALLOWED_CIDR` | documentation range | Keep the real value in `terraform.tfvars`, not this template |

Place the administrator public key on the host:

```bash
cp ~/.ssh/bastion_admin.pub runtime/authorized_keys/bastion
chmod 0644 runtime/authorized_keys/bastion
```

The entrypoint stages keys into tmpfs as `root:root 0644`, because sshd's
privilege-separated child must read them and Windows bind mounts report
world-writable permissions. Restart the container after changing a key.

---

## Phase 5 — Terraform inputs

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

- [ ] `tenancy_ocid` and `compartment_ocid` are real OCIDs.
- [ ] `region` matches the console.
- [ ] `allowed_ssh_cidr` is your `/32` or VPN range, never `0.0.0.0/0`.
- [ ] `ssh_public_key` is the **content** of `~/.ssh/bastion_admin.pub`
      (one line starting `ssh-ed25519 `).
- [ ] `instance_shape` is `VM.Standard.A1.Flex` or the documented fallback.
- [ ] `vcn_cidr` / `subnet_cidr` do not collide with another project.
- [ ] `terraform.tfvars` is not staged or tracked.

Validate before planning:

```bash
TOFU=/c/Users/Kaveh/Desktop/CloudGuard/.cloudguard/tools/tofu/tofu.exe
"$TOFU" init
"$TOFU" fmt -recursive -check
"$TOFU" validate
```

- [ ] `Success! The configuration is valid.` is printed.
- [ ] `git check-ignore -v terraform.tfvars` and `terraform.tfstate` both match.
- [ ] I have not run `apply` merely to test syntax.

`tofu plan` is a deployment-stage step and needs working credentials. Review it
before applying. The expected graph is six resources: VCN, internet gateway,
route table, security list, subnet, instance.

---

## Phase 6 — Local pre-cloud smoke test

Run this before spending trial credits. It proves the image and key path:

```bash
cd ..      # repository root
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml ps

ssh -p 2222 -i ~/.ssh/bastion_admin \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  bastion@127.0.0.1 'id -un; echo bastion-ok'
```

- [ ] Container status is `(healthy)`.
- [ ] SSH prints `bastion` and `bastion-ok`.
- [ ] Password auth and root login both fail.
- [ ] `runtime/audit/sessions.jsonl` contains a session record.
- [ ] `git status --porcelain` is clean (runtime files are ignored).

---

## Phase 7 — Pre-deployment checklist

All boxes are required before an apply:

- [ ] OCI API key works and `~/.oci/config` is mode `600` outside the repo.
- [ ] Trial credits or Always Free entitlement is active; budget alert exists.
- [ ] Compartment and region are correct.
- [ ] `allowed_ssh_cidr` is a specific `/32` or VPN range, not the world.
- [ ] `ssh_public_key` is public key content, not a private key.
- [ ] `.env` exists with mode `600`; `runtime/` directories exist.
- [ ] `.env`, `terraform.tfvars`, state and runtime material are gitignored.
- [ ] `tofu fmt -check` and `tofu validate` pass.
- [ ] Local container smoke test passes.
- [ ] Security list review: only TCP/22 ingress; no 80/443/ICMP/management.
- [ ] I have a host-key backup and audit-retention plan.
- [ ] I have an explicit teardown plan and know this is the project's own
      compartment.

---

## Phase 8 — Deployment-day sequence (later stage; not run in Stage 3)

This phase is intentionally documented but **not executed** here. A deployment
stage must record live evidence; Stage 3 does not claim it.

```bash
cd terraform
"$TOFU" plan
# Review: six resources, one ingress rule (22 from allowed_ssh_cidr).
"$TOFU" apply
"$TOFU" output instance_public_ip

ssh ubuntu@<instance_public_ip>
cloud-init status --wait
docker --version
```

Then install the stack over SSH, without putting any secret in user-data:

```bash
git clone https://github.com/kaveh8866/Bastion-Host-Jump-Server.git
cd Bastion-Host-Jump-Server
mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit
cp .env.example .env && chmod 600 .env
# add your public key to runtime/authorized_keys/bastion
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
```

Post-deploy checks:

- [ ] Security list admits only 22; test from outside with `nc -vz <ip> 22`.
- [ ] Host SSH works; cloud-init completed.
- [ ] Container is healthy on loopback 2222.
- [ ] A real session writes a JSONL audit record.
- [ ] Password and root login are refused.
- [ ] No 2222/tcp rule was added without a separate, reviewed decision.
- [ ] Evidence is recorded in the deployment stage's transcript.

---

## Phase 9 — Teardown (only on explicit operator request)

Do not destroy while another project uses the compartment. When asked:

```bash
docker compose --env-file .env -f docker/docker-compose.yml down
cd terraform
"$TOFU" plan -destroy
# Review, then:
"$TOFU" destroy
"$TOFU" state list
```

- [ ] Plan reviewed and approved by the operator.
- [ ] Destroy exits 0.
- [ ] `tofu state list` is empty.
- [ ] Provider-side check shows no remaining bastion instance, VCN or subnet.
- [ ] State file removed only after provider verification.
- [ ] Host keys and audit records are retained/archived per policy, not
      committed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Permission denied (publickey)` | Key not in the staged tmpfs, or stale container | Check `docker logs`, key file, then restart the container |
| `account is locked` | Base image account not unlocked | Rebuild from the current Dockerfile; do not enable passwords |
| `Could not open ... authorized keys` | staged key permissions | Use the current entrypoint (root:root 0644); do not disable StrictModes |
| `tofu validate`: provider mismatch | Module missing `oracle/oci` source | Keep `versions.tf` in both modules |
| `tofu validate`: VNIC attribute | Wrong provider attribute name | Use `public_ip_address` / `private_ip_address` |
| Out of host capacity | A1.Flex exhausted in the AD | Try another AD, then the E2.1.Micro fallback |
| Cloud SSH timeout | Source IP changed or missing rule | Confirm current `/32` and the single TCP/22 ingress rule |
| Container healthy but unreachable from outside | Expected: 2222 is loopback-only | Use host SSH/tunnel; do not widen the firewall casually |
| Audit hook denies login | audit mount unwritable | Fix ownership/mode of `runtime/audit`; fail-closed is intentional |

---

## Certification scope

- The container and IaC are **Cloud-Agnostic** (supporting AWS, GCP and OCI);
  AWS and GCP mappings are documented in `terraform/README.md` and the module
  comments.
- **Final production verification and testing certification are performed
  strictly on Oracle Cloud Infrastructure (OCI) using trial credits.** AWS and
  GCP are ports, not certified targets.
- In short: final production verification and testing certification are
  performed strictly on OCI using trial credits; no AWS or GCP certification
  run is claimed.
- Stage 3 is documentation plus locally validated configuration. No OCI
  resource has been planned, applied or destroyed, and no live host, live jump
  or production certification is claimed. Live evidence belongs to the
  deployment stage.
