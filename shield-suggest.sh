#!/bin/bash
# Suggest domains associated with blocked traffic; never changes the allowlist.
# --since limits blocked traffic, while DNS queries from this boot are used for
# correlation even when they occurred before that window.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ID=${1:?usage: shield-suggest.sh <deployment-id> [--since <spec>]}
SINCE=
if [ $# -gt 1 ]; then
    [ "$#" -eq 3 ] && [ "$2" = --since ] && [ -n "$3" ] || {
        echo 'usage: shield-suggest.sh <deployment-id> [--since <spec>]' >&2; exit 1;
    }
    SINCE=$3
fi
[[ "$ID" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'ERROR: invalid deployment ID' >&2; exit 1; }
[ -f "keys/$ID.pem" ] || { echo "ERROR: no keys/$ID.pem — run from the deploy dir" >&2; exit 1; }
source shield/connection.sh
# Base64 keeps the journalctl time expression data, not remote shell syntax.
SINCE64=$(printf '%s' "$SINCE" | base64 | tr -d '\n')
$SSH "python3 - '$ID' '$SINCE64'" < shield/suggest.py
