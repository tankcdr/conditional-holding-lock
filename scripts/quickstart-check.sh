#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Build and run the consumer quickstart end to end on an isolated sandbox.
#
# Usage: scripts/quickstart-check.sh [dar-dir]
#   dar-dir   Directory containing every DAR docs/quickstart/daml.yaml lists.
#             When omitted, the DARs are assembled from the local build
#             outputs (this is what makes the quickstart runnable before any
#             release tag exists).
#
# Env:
#   NETWORK   Canton network to run against (default: testnet)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
. "$ROOT/scripts/lib/sandbox.sh"
conditional_lock_java

NETWORK="${NETWORK:-testnet}"
DAR_DIR="${1:-}"
QUICKSTART_DARS="$ROOT/docs/quickstart/dars"

rm -rf "$QUICKSTART_DARS"
mkdir -p "$QUICKSTART_DARS"

if [[ -n "$DAR_DIR" ]]; then
  echo "==> populating quickstart DARs from $DAR_DIR"
  cp "$DAR_DIR"/*.dar "$QUICKSTART_DARS/"
else
  echo "==> building local first-party packages"
  "$ROOT/scripts/build-dars.sh"
  cp "$ROOT/.dars/"*.dar "$QUICKSTART_DARS/"
  cp "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/splice-api-token-conditional-lock-v1-1.0.0.dar" "$QUICKSTART_DARS/"
  cp "$ROOT/packages/conditional-lock-utils/.daml/dist/conditional-lock-utils-1.0.0.dar" "$QUICKSTART_DARS/"
  cp "$ROOT/packages/conditional-lock-test-token/.daml/dist/conditional-lock-test-token-1.0.0.dar" "$QUICKSTART_DARS/"
fi

run_dir="$(mktemp -d "$ROOT/.localnet/quickstart-$NETWORK.XXXXXX")"
conditional_lock_sandbox_start "$NETWORK" "$run_dir"
cleanup() { kill "$CL_SANDBOX_PID" 2>/dev/null || true; wait "$CL_SANDBOX_PID" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> uploading consumer DARs in dependency order"
for dar in splice-api-token-conditional-lock-v1-1.0.0.dar conditional-lock-utils-1.0.0.dar conditional-lock-test-token-1.0.0.dar; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$CL_JSON_PORT/v2/packages" \
    -H "Content-Type: application/octet-stream" --data-binary @"$QUICKSTART_DARS/$dar")"
  case "$status" in
    2??|409) ;;
    *) echo "Unexpected status $status uploading $dar" >&2; exit 1 ;;
  esac
done

echo "==> building the quickstart"
(cd "$ROOT/docs/quickstart" && dpm build)

echo "==> running the quickstart script"
dpm script --dar "$ROOT/docs/quickstart/.daml/dist/conditional-lock-quickstart-1.0.0.dar" \
  --script-name Quickstart:quickstart --ledger-host 127.0.0.1 --ledger-port "$CL_LEDGER_PORT" \
  --static-time --upload-dar yes

canton_version="$(curl -fsS "http://127.0.0.1:$CL_JSON_PORT/v2/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
echo "PASS $NETWORK; Canton $canton_version; DARs from ${DAR_DIR:-$ROOT/.dars and packages/*/.daml/dist}"
