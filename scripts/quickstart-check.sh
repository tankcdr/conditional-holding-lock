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
  cp "$DAR_DIR"/*.dar "$QUICKSTART_DARS/" 2>/dev/null || true
else
  echo "==> building local first-party packages"
  "$ROOT/scripts/build-dars.sh"
  cp "$ROOT/.dars/"*.dar "$QUICKSTART_DARS/"
  cp "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/splice-api-token-conditional-lock-v1-1.0.0.dar" "$QUICKSTART_DARS/"
  cp "$ROOT/packages/conditional-lock-utils/.daml/dist/conditional-lock-utils-1.0.0.dar" "$QUICKSTART_DARS/"
  cp "$ROOT/packages/conditional-lock-test-token/.daml/dist/conditional-lock-test-token-1.0.0.dar" "$QUICKSTART_DARS/"
fi

# Fail on a missing DAR before paying for a sandbox, naming every one that is
# absent, rather than dying on a raw compiler error twenty seconds later.
required=()
while IFS= read -r dar; do required+=("$dar"); done \
  < <(sed -n 's|^[[:space:]]*-[[:space:]]*"\{0,1\}dars/||p' "$ROOT/docs/quickstart/daml.yaml" | tr -d '"')
if [[ ${#required[@]} -eq 0 ]]; then
  echo "Parsed no dars/ entries out of docs/quickstart/daml.yaml; the precondition check would silently pass." >&2
  exit 1
fi
missing=()
for dar in "${required[@]}"; do
  [[ -f "$QUICKSTART_DARS/$dar" ]] || missing+=("$dar")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing from ${DAR_DIR:-$QUICKSTART_DARS}, required by docs/quickstart/daml.yaml:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "See docs/adoption.md section 2; the quickstart needs more than the two Splice DARs an application compiles against." >&2
  exit 1
fi

mkdir -p "$ROOT/.localnet"
run_dir="$(mktemp -d "$ROOT/.localnet/quickstart-$NETWORK.XXXXXX")"
# sandbox.sh registers the kill/wait traps itself, before its startup wait.
conditional_lock_sandbox_start "$NETWORK" "$run_dir"

echo "==> uploading consumer DARs in dependency order"
LEDGER_JSON_API="http://127.0.0.1:$CL_JSON_PORT" "$ROOT/scripts/deploy-dars.sh" \
  "$QUICKSTART_DARS/splice-api-token-conditional-lock-v1-1.0.0.dar" \
  "$QUICKSTART_DARS/conditional-lock-utils-1.0.0.dar" \
  "$QUICKSTART_DARS/conditional-lock-test-token-1.0.0.dar"

echo "==> building the quickstart"
(cd "$ROOT/docs/quickstart" && dpm build)

echo "==> running the quickstart script"
dpm script --dar "$ROOT/docs/quickstart/.daml/dist/conditional-lock-quickstart-1.0.0.dar" \
  --script-name Quickstart:quickstart --ledger-host 127.0.0.1 --ledger-port "$CL_LEDGER_PORT" \
  --static-time --upload-dar yes

canton_version="$(curl -fsS "http://127.0.0.1:$CL_JSON_PORT/v2/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
echo "PASS $NETWORK; Canton $canton_version; DARs from ${DAR_DIR:-$ROOT/.dars and packages/*/.daml/dist}"
