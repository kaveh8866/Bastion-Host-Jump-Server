# Container runtime

## Build and start

```bash
mkdir -p runtime/host_keys runtime/authorized_keys runtime/audit
cp -n .env.example .env
# Put the operator public key in runtime/authorized_keys/bastion first.
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml ps
```

The first start generates an ed25519 host key in `runtime/host_keys`. The
entrypoint copies `runtime/authorized_keys/*` into tmpfs as `root:root 0644`
(needed for `StrictModes` on Windows bind mounts and readable by sshd's
privilege-separated child), so restart the container after changing a key. The
container is healthy when `ssh-keyscan -t ed25519 -p 2222 127.0.0.1` returns a
key.

## Why the flags are shaped this way

| Flag | Reason |
| --- | --- |
| `read_only: true` | The daemon has no reason to modify its image; keys and audit records are mounts |
| `cap_drop: ALL` | Start from zero capabilities, not the Docker default set |
| `cap_add: CHOWN, SETGID, SETUID, SYS_CHROOT` | The minimum sshd needs to separate privileges and enter the user session |
| `no-new-privileges:true` | Blocks setuid escalation inside the container |
| `pids_limit: 128` | Bounds process creation from a broken or hostile session |
| `mem_limit` / `cpus` | Fits the smallest OCI free shape; leaves host headroom |
| `tmpfs /run` | sshd needs a writable privilege-separation directory |
| `tmpfs /tmp` | Ephemeral, non-executable scratch space |
| `json-file` rotation | Container logs cannot grow without bound |

The container does not run as a non-root `USER`: sshd must be the root master to
authenticate and then drop to `bastion`. All session processes run as uid 1000.

## Ports and exposure

Compose publishes `127.0.0.1:2222` by default. Setting
`BASTION_SSH_BIND_ADDRESS=0.0.0.0` exposes the listener; do that only with a
cloud firewall rule restricted to the operator `/32`.

## Stop and clean up

```bash
docker compose --env-file .env -f docker/docker-compose.yml down
# Runtime material is intentionally preserved:
# runtime/host_keys, runtime/authorized_keys, runtime/audit
```

Deleting `runtime/` invalidates client host-key trust. It is gitignored, so it
never enters a commit.
