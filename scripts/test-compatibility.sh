#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run the actual Ledger API proofs on the mainnet/testnet Canton versions.
# Each run owns a fresh in-memory ledger and its process; Docker is untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
conditional_lock_java
"$ROOT/scripts/build-dars.sh"
DAR="$ROOT/packages/conditional-lock-test/.daml/dist/conditional-lock-test-1.0.0.dar"
networks=("$@")
if [[ ${#networks[@]} -eq 0 ]]; then networks=(mainnet testnet); fi

run_network() (
  network="$1"
  case "$network" in mainnet|testnet) ;; *) echo "Expected mainnet or testnet" >&2; exit 1 ;; esac
  binary="$(python3 "$ROOT/scripts/fetch-canton.py" "$network")"
  run_dir="$(mktemp -d "$ROOT/.localnet/compatibility-$network.XXXXXX")"
  # Canton internally connects to the configured ports, so port 0 cannot be
  # used here. Select unused loopback ports together before launching it.
  read -r ledger admin json sequencer seq_admin mediator < <(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(6)]
for s in sockets:
    s.bind(('127.0.0.1', 0))
print(*(s.getsockname()[1] for s in sockets))
for s in sockets:
    s.close()
PY
)
  echo "==> $network compatibility: $binary (evidence: $run_dir)"
  "$binary" sandbox --static-time \
    --ledger-api-port "$ledger" --admin-api-port "$admin" --json-api-port "$json" \
    --sequencer-public-port "$sequencer" --sequencer-admin-port "$seq_admin" --mediator-admin-port "$mediator" \
    --canton-port-file "$run_dir/ports.json" --log-file-name "$run_dir/canton.log" \
    --log-level-stdout WARN >"$run_dir/console.log" 2>&1 &
  canton_pid=$!
  cleanup() { kill "$canton_pid" 2>/dev/null || true; wait "$canton_pid" 2>/dev/null || true; }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for ((attempt = 0; attempt < 120; attempt++)); do
    [[ -f "$run_dir/ports.json" ]] && break
    if ! kill -0 "$canton_pid" 2>/dev/null; then
      tail -60 "$run_dir/console.log" >&2
      exit 1
    fi
    sleep 1
  done
  [[ -f "$run_dir/ports.json" ]] || { echo "Canton startup timed out: $run_dir" >&2; exit 1; }
  curl -fsS "http://127.0.0.1:$json/v2/version" > "$run_dir/ledger-version.json"
  dpm script --dar "$DAR" --all --ledger-host 127.0.0.1 --ledger-port "$ledger" \
    --static-time --upload-dar yes --json-test-summary "$run_dir/results.json" 2>&1 | tee "$run_dir/tests.log"
  python3 "$ROOT/scripts/record-proof.py" "$network" "$run_dir"
  echo "PASS $network; evidence in $run_dir"
)

for network in "${networks[@]}"; do run_network "$network"; done
