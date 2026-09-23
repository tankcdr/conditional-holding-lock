#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Prove the conditional lock on the running Mainnet-configuration localnet.
#
#   ./scripts/localnet.sh          # up + bootstrap (once)
#   ./scripts/localnet-prove.sh    # the proof
#
# Runs the escrowed-DvP-with-a-dispute-window reference deployment
# (examples/devnet-escrow) against the localnet's app-provider participant under
# wall-clock time: the settle path enacts jointly before the deadline, the
# arbiter's award path after it, from one set of LockTerms. Evidence is written
# by scripts/record-reference-proof.py to
# docs/runbook/localnet-mainnet-<IMAGE_TAG>-reference-evidence.json.
#
# The endpoint comes from .env.localnet; the bearer token is minted by
# scripts/lib/localnet_token.py and passed in the environment only -- never in
# argv, never printed. Do not add `set -x` to this script.
#
# WINDOW=<seconds> overrides the dispute window (default 45; a real
# synchronizer is slower than the in-process sandbox the default 20 was sized
# for). Any further arguments are passed through to devnet-reference.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/localnet-compose.sh
. "$ROOT/scripts/lib/localnet-compose.sh"

localnet_env

: "${LEDGER_JSON_API:?.env.localnet must set LEDGER_JSON_API}"
: "${LEDGER_HOST:?.env.localnet must set LEDGER_HOST}"
: "${LEDGER_PORT:?.env.localnet must set LEDGER_PORT}"

if ! curl -s -o /dev/null -w '%{http_code}' "$LEDGER_JSON_API/v2/version" | grep -qE '^(200|401)$'; then
  printf '[ERROR] no participant at %s. Start the localnet with ./scripts/localnet.sh first.\n' \
    "$LEDGER_JSON_API" >&2
  exit 1
fi

LEDGER_TOKEN="$(python3 "$ROOT/scripts/lib/localnet_token.py" --node app-provider --localnet-dir "$LOCALNET_DIR")"
export LEDGER_TOKEN
exec "$ROOT/scripts/devnet-reference.sh" \
  --network localnet-mainnet \
  --runtime-tag "$IMAGE_TAG" \
  --window "${WINDOW:-45}" \
  "$@"
