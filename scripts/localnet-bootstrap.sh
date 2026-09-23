#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build the first-party conditional-lock DARs and upload them onto a running
# localnet's participants.
#
# BOTH the app-provider and the app-user participant get the DARs, not just the
# one this repository submits from. A conditional lock is a multi-party
# contract: the receiver's account parties are signatories of the active lock
# and observers of the instruction, so the receiver's participant is an informee
# of every lock transaction, and Canton rejects a transaction whose informee
# participant cannot resolve the package. On this localnet the receiver lives on
# app-user, so uploading only to app-provider leaves every cross-participant
# lock failing at confirmation rather than at submission.
#
# Upload goes through scripts/deploy-dars.sh, the single /v2/packages upload
# path in this repository; this script contributes only the localnet's endpoints
# and their bearer tokens.
#
# The tokens are minted by scripts/lib/localnet_token.py from the vendored
# Splice tree's own auth configuration (user `ledger-api-user`, audience and
# HS256 secret read out of env/<node>-auth-on.env and
# conf/canton/<node>/app-auth.conf). They are passed to deploy-dars.sh in the
# environment only, never in argv and never printed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/localnet-compose.sh
. "$ROOT/scripts/lib/localnet-compose.sh"

info() { printf '[INFO]  %s\n' "$*"; }

localnet_env

JSON_API="${LEDGER_JSON_API:?.env.localnet must set LEDGER_JSON_API}"

info "building DARs"
"$ROOT/scripts/build-dars.sh"

# The three attached first-party packages, read from dar_identity.py's PACKAGES
# so a rename there cannot leave a stale literal here.
read -r CL_TOKEN_DAR CL_UTILS_DAR CL_TEST_TOKEN_DAR < <(python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
import dar_identity
print(*[dar_identity.built_dar_path(p).name for p, attached in dar_identity.PACKAGES if attached])
")

# The app-user participant's JSON API, derived from the app-provider one by
# scripts/lib/localnet_endpoints.py, the single derivation of every localnet
# endpoint. If LEDGER_JSON_API does not conform to Splice's <node><suffix>
# port pattern, that script fails hard here: the app-user upload below is not
# optional, so there is no "skip and continue" path for it to fall back to.
APP_USER_JSON_API="$(python3 "$ROOT/scripts/lib/localnet_endpoints.py" --ledger-json-api "$JSON_API" --get user_json_api)"

upload_to() {
  local node="$1" endpoint="$2"
  info "minting a $node token: $(python3 "$ROOT/scripts/lib/localnet_token.py" --node "$node" --describe --localnet-dir "$LOCALNET_DIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["user"] + " @ " + d["audience"] + " (" + d["secret_source"] + ")")')"
  info "uploading to the $node participant at $endpoint"
  LEDGER_JSON_API="$endpoint" \
  LEDGER_TOKEN="$(python3 "$ROOT/scripts/lib/localnet_token.py" --node "$node" --localnet-dir "$LOCALNET_DIR")" \
    "$ROOT/scripts/deploy-dars.sh" \
      "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/$CL_TOKEN_DAR" \
      "$ROOT/packages/conditional-lock-utils/.daml/dist/$CL_UTILS_DAR" \
      "$ROOT/packages/conditional-lock-test-token/.daml/dist/$CL_TEST_TOKEN_DAR"
}

upload_to app-provider "$JSON_API"
upload_to app-user "$APP_USER_JSON_API"

info "bootstrap complete"
