#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run the actual Ledger API proofs on the mainnet/testnet Canton versions.
# Each run owns a fresh in-memory ledger and its process; Docker is untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
. "$ROOT/scripts/lib/sandbox.sh"
conditional_lock_java
"$ROOT/scripts/build-dars.sh"
DAR="$ROOT/packages/conditional-lock-test/.daml/dist/conditional-lock-test-1.0.0.dar"
networks=("$@")
if [[ ${#networks[@]} -eq 0 ]]; then networks=(mainnet testnet); fi

run_network() (
  network="$1"
  mkdir -p "$ROOT/.localnet"
  run_dir="$(mktemp -d "$ROOT/.localnet/compatibility-$network.XXXXXX")"
  # sandbox.sh registers the kill/wait traps itself, before its startup wait.
  conditional_lock_sandbox_start "$network" "$run_dir"
  curl -fsS "http://127.0.0.1:$CL_JSON_PORT/v2/version" > "$run_dir/ledger-version.json"
  dpm script --dar "$DAR" --all --ledger-host 127.0.0.1 --ledger-port "$CL_LEDGER_PORT" \
    --static-time --upload-dar yes --json-test-summary "$run_dir/results.json" 2>&1 | tee "$run_dir/tests.log"
  python3 "$ROOT/scripts/record-proof.py" "$network" "$run_dir"
  echo "PASS $network; evidence in $run_dir"
)

for network in "${networks[@]}"; do run_network "$network"; done
