#!/bin/sh
# =============================================================================
# Bastion Host / Jump Server — session audit hook
# =============================================================================
# Invoked by sshd's ForceCommand for every interactive or command session.
# Appends one JSON object per session to an append-only JSONL file on the
# mounted audit volume, then executes what the client asked for.
#
# The audit file can contain command text and must remain outside Git. The
# hook fails closed: if the record cannot be written, the session is denied.
set -eu

AUDIT_DIR="${BASTION_AUDIT_DIR:-/var/log/bastion}"
AUDIT_FILE="${BASTION_AUDIT_FILE:-${AUDIT_DIR}/sessions.jsonl}"
umask 077

mkdir -p "$AUDIT_DIR" 2>/dev/null || true

timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
user="${USER:-${LOGNAME:-unknown}}"

# SSH_CONNECTION is "client_ip client_port server_ip server_port". Keep the
# client address only; never log the server-side socket details.
set -- ${SSH_CONNECTION:-}
source_addr="${1:-${SSH_CLIENT%% *}}"
[ -n "$source_addr" ] || source_addr="unknown"

original_command="${SSH_ORIGINAL_COMMAND:-}"
action="shell"
[ -n "$original_command" ] && action="command"

if ! jq -cn \
      --arg timestamp "$timestamp" \
      --arg user "$user" \
      --arg source "$source_addr" \
      --arg action "$action" \
      --arg command "$original_command" \
      '{timestamp:$timestamp,user:$user,source:$source,action:$action,command:$command}' \
      >> "$AUDIT_FILE"; then
  echo "bastion: session audit unavailable; denying session" >&2
  exit 1
fi

if [ -n "$original_command" ]; then
  exec /bin/sh -c "$original_command"
fi

exec /bin/sh -l
