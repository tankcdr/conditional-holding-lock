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
# The endpoint comes from .env.localnet. The credential is the participant
# ADMIN token (scripts/lib/localnet_token.py --admin), not the HS256 user token
# the DAR upload uses: Daml Script allocates its own parties at runtime and
# Canton grants act-as rights only to the user named in an AllocateParty
# request's `userId`, which Daml Script does not set, so a user token cannot
# act as the parties the script just created. The admin token carries
# ClaimActAsAnyParty. Authentication stays ON either way. It is passed in the
# environment only -- never in argv, never printed. Do not add `set -x` here.
#
# ONE RUN PER FRESH LEDGER. Daml Script derives a deterministic party-id hint
# (`alice-d4d95138`), so a second run against the same persistent participant
# fails at allocateParty with "Party already exists". The preflight below says
# so rather than letting the run get halfway there. On the in-process sandbox
# (`--network localnet`) this does not arise: that ledger is new every time.
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

LEDGER_TOKEN="$(python3 "$ROOT/scripts/lib/localnet_token.py" --node app-provider --admin)"
export LEDGER_TOKEN
# The admin token has no user-id claim, so the submission has to name a ledger
# user explicitly. Use the participant's own validator user, the same one the
# DAR upload authenticates as.
LEDGER_USER_ID="${LEDGER_USER_ID:-$(python3 "$ROOT/scripts/lib/localnet_token.py" --node app-provider --describe | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"])')}"
export LEDGER_USER_ID

# Preflight: the reference deployment's four parties, from a previous run.
header_file="$(mktemp)"
trap 'rm -f "$header_file"' EXIT
chmod 600 "$header_file"
printf 'Authorization: Bearer %s' "$LEDGER_TOKEN" > "$header_file"
stale="$(curl -sS -H "@${header_file}" "$LEDGER_JSON_API/v2/parties?pageSize=1000" | python3 -c '
import json, re, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
pattern = re.compile(r"^(alice|bob|arbiter|admin)-[0-9a-f]{8}::")
print(" ".join(sorted({
    d["party"].split("::")[0] for d in doc.get("partyDetails", [])
    if d.get("isLocal") and pattern.match(d["party"])
})))
')"
if [[ -n "$stale" ]]; then
  cat >&2 <<MSG
[ERROR] this participant has already hosted a reference deployment: $stale
        Daml Script allocates deterministic party-id hints, so a persistent
        ledger can run the reference deployment exactly once. Reset it:

            ./scripts/localnet.sh --clean && ./scripts/localnet.sh
            ./scripts/localnet-prove.sh
MSG
  exit 1
fi
exec "$ROOT/scripts/devnet-reference.sh" \
  --network localnet-mainnet \
  --runtime-tag "$IMAGE_TAG" \
  --window "${WINDOW:-45}" \
  "$@"
