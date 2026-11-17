# syntax=docker/dockerfile:1.7
# =============================================================================
# Bastion Host / Jump Server — runtime image
# =============================================================================
# Multi-arch (linux/amd64, linux/arm64), sized for an OCI Always Free micro or
# A1.Flex instance. The image contains an SSH daemon, a session-audit hook and
# jq; it deliberately contains no compiler, no package cache and no host keys.
#
# Build context is the repository root:
#   docker build -f docker/Dockerfile -t cloudguard/bastion:local .

FROM alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2

LABEL org.opencontainers.image.title="CloudGuard Bastion Host / Jump Server" \
      org.opencontainers.image.description="Key-only SSH jump host with session auditing and restricted forwarding" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/kaveh8866/Bastion-Host-Jump-Server"

ENV TZ=UTC \
    BASTION_AUDIT_DIR=/var/log/bastion \
    BASTION_HOST_KEY_DIR=/etc/ssh/host_keys

# openssh-server is the service; jq builds structured audit records; tini reaps
# the daemon. ssh-keyscan from openssh-client is used by the healthcheck.
#
# Alpine's adduser leaves the password field locked, and sshd rejects a locked
# account before it considers a public key. Clear the field: password and
# keyboard-interactive authentication are disabled in sshd_config.
RUN apk add --no-cache openssh-server openssh-client jq tini \
 && addgroup -g 1000 bastion \
 && adduser -D -u 1000 -G bastion -s /bin/sh bastion \
 && passwd -d bastion \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /etc/ssh/host_keys /etc/ssh/authorized_keys /var/log/bastion /run/sshd \
 && chmod 0700 /etc/ssh/host_keys \
 && chown 1000:1000 /var/log/bastion

COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bastion/session-audit.sh /usr/local/bin/session-audit

RUN chmod 0644 /etc/ssh/sshd_config \
 && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/session-audit

EXPOSE 2222
STOPSIGNAL SIGTERM

# sshd must start as root to perform privilege separation and drop to the
# unprivileged user; Compose removes every capability except the four needed
# (CHOWN, SETGID, SETUID, SYS_CHROOT). No application process runs as root.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
