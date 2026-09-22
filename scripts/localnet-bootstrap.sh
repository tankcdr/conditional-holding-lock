#!/usr/bin/env bash
# Build first-party CIP DARs and upload them onto a running localnet participant.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
JSON_API="${CANTON_API_URL:-http://localhost:3975}"

info() { printf '[INFO]  %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

info "building DARs"
"$ROOT/scripts/build-dars.sh"

upload() {
  local dar="$1"
  [ -f "$dar" ] || { error "missing $dar"; exit 1; }
  local code
  code=$(curl -sS -o /tmp/localnet-upload.json -w '%{http_code}' -X POST \
    "${JSON_API}/v2/packages" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$dar" || true)
  case "$code" in
    2*|409) info "uploaded $(basename "$dar") (HTTP $code)" ;;
    *) error "upload failed $(basename "$dar") (HTTP $code) $(head -c 200 /tmp/localnet-upload.json 2>/dev/null || true)"; exit 1 ;;
  esac
}

upload "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/splice-api-token-conditional-lock-v1-1.0.0.dar"

info "bootstrap complete"
