#!/bin/sh
# =============================================================================
# Bastion Host / Jump Server — container entrypoint
# =============================================================================
# Generates the ed25519 host key once, into the mounted runtime directory, and
# validates the daemon configuration before handing PID 1 to sshd. The root
# filesystem can stay read-only because all writable state is mounted.
set -eu

umask 077

HOST_KEY_DIR="${BASTION_HOST_KEY_DIR:-/etc/ssh/host_keys}"
AUTHORIZED_KEYS_DIR="${BASTION_AUTHORIZED_KEYS_DIR:-/etc/ssh/authorized_keys}"
AUDIT_DIR="${BASTION_AUDIT_DIR:-/var/log/bastion}"
HOST_KEY="${HOST_KEY_DIR}/ssh_host_ed25519_key"
RUNTIME_KEYS_DIR="/run/authorized_keys"

mkdir -p "$HOST_KEY_DIR" "$AUTHORIZED_KEYS_DIR" "$AUDIT_DIR" /run/sshd "$RUNTIME_KEYS_DIR"
chmod 0700 "$HOST_KEY_DIR"
chmod 0755 "$RUNTIME_KEYS_DIR"

# Stage public keys into tmpfs with root:root 0644. This keeps StrictModes
# effective even when the source mount (Windows) reports world-writable
# permissions, and it prevents sshd from reading directly from a writable
# mount. The keys are public material; 0644 lets the privilege-separated sshd
# child read them without granting it DAC_OVERRIDE. Key changes require a
# container restart.
for key_file in "$AUTHORIZED_KEYS_DIR"/*; do
  [ -f "$key_file" ] || continue
  key_name=$(basename "$key_file")
  cp "$key_file" "${RUNTIME_KEYS_DIR}/${key_name}"
  chown root:root "${RUNTIME_KEYS_DIR}/${key_name}"
  chmod 0644 "${RUNTIME_KEYS_DIR}/${key_name}"
done

# The audit hook runs as the unprivileged user. The bind mount is created by
# the operator; fixing ownership here keeps the image compatible with a fresh
# runtime directory without weakening sshd itself.
chown 1000:1000 "$AUDIT_DIR" 2>/dev/null || true

if [ ! -s "$HOST_KEY" ]; then
  echo "bastion: generating ed25519 host key in $HOST_KEY_DIR" >&2
  ssh-keygen -q -t ed25519 -a 100 -N '' -C "cloudguard-bastion" -f "$HOST_KEY"
fi
chmod 0600 "$HOST_KEY"
chmod 0644 "${HOST_KEY}.pub"

# Fail closed on an invalid configuration rather than starting a daemon with
# unknown authentication or forwarding behaviour.
/usr/sbin/sshd -t -f /etc/ssh/sshd_config

echo "bastion: starting sshd on 0.0.0.0:2222" >&2
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
