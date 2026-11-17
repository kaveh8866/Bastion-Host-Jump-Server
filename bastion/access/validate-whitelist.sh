#!/bin/sh
# =============================================================================
# Bastion access whitelist validator
# =============================================================================
# Usage: ./validate-whitelist.sh [path]   (default: whitelist.example.json)
# Requires jq. The schema in configs/whitelist.schema.json is the full contract;
# this check enforces the fields sshd/proxy automation depends on.
set -eu

file="${1:-$(dirname "$0")/whitelist.example.json}"
[ -r "$file" ] || { echo "whitelist not readable: $file" >&2; exit 2; }

if ! jq -e '
  .version == 1 and
  (.users | type == "array" and length > 0) and
  all(.users[];
    (.name | type == "string" and length > 0) and
    (.public_key | type == "string" and startswith("ssh-")) and
    (.source_cidrs | type == "array" and length > 0) and
    all(.source_cidrs[];
      test("^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/([0-9]|[12][0-9]|3[0-2])$") and
      . != "0.0.0.0/0"
    ) and
    (.targets | type == "array" and length > 0) and
    all(.targets[];
      (.host | type == "string" and length > 0) and
      (.port | type == "number" and . >= 1 and . <= 65535)
    )
  )
' "$file" >/dev/null; then
  echo "whitelist invalid: $file (schema or source CIDR rejected)" >&2
  exit 1
fi

echo "whitelist valid: $file"
