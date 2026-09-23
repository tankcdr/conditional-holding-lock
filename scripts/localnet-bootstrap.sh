#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build the first-party conditional-lock DARs and upload them onto a running
# localnet's app-provider participant.
#
# Upload goes through scripts/deploy-dars.sh, the single /v2/packages upload
# path in this repository; this script contributes only the localnet's endpoint
# and its bearer token.
#
# The token is minted by scripts/lib/localnet_token.py from the vendored Splice
# tree's own auth configuration (user `ledger-api-user`, audience and HS256
# secret read out of env/app-provider-auth-on.env and
# conf/canton/app-provider/app-auth.conf). It is passed to deploy-dars.sh in the
# environment only, never in argv and never printed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/localnet-compose.sh
. "$ROOT/scripts/lib/localnet-compose.sh"

info() { printf '[INFO]  %s\n' "$*"; }

localnet_env

JSON_API="${LEDGER_JSON_API:-${CANTON_API_URL:-http://localhost:3975}}"

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

info "minting an app-provider token: $(python3 "$ROOT/scripts/lib/localnet_token.py" --describe --localnet-dir "$LOCALNET_DIR" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["user"] + " @ " + d["audience"] + " (" + d["secret_source"] + ")")')"

info "uploading to $JSON_API"
LEDGER_JSON_API="$JSON_API" \
LEDGER_TOKEN="$(python3 "$ROOT/scripts/lib/localnet_token.py" --node app-provider --localnet-dir "$LOCALNET_DIR")" \
  "$ROOT/scripts/deploy-dars.sh" \
    "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/$CL_TOKEN_DAR" \
    "$ROOT/packages/conditional-lock-utils/.daml/dist/$CL_UTILS_DAR" \
    "$ROOT/packages/conditional-lock-test-token/.daml/dist/$CL_TEST_TOKEN_DAR"

info "bootstrap complete"
