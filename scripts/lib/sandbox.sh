# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Shared Canton sandbox launch: fetch the pinned binary, pick loopback ports,
# start the sandbox in the background, and wait for it to publish its ports.
# The caller owns the trap/cleanup around the exported CL_SANDBOX_PID.

# conditional_lock_sandbox_start <network> <run_dir>
#
# On success, sets/exports:
#   CL_SANDBOX_PID   background PID of the sandbox process
#   CL_LEDGER_PORT   Ledger API port
#   CL_ADMIN_PORT    Admin API port
#   CL_JSON_PORT     JSON Ledger API port
conditional_lock_sandbox_start() {
  local network="$1"
  local run_dir="$2"
  local root="$ROOT"
  local binary ledger admin json sequencer seq_admin mediator attempt

  case "$network" in mainnet|testnet) ;; *) echo "Expected mainnet or testnet" >&2; return 1 ;; esac

  binary="$(python3 "$root/scripts/fetch-canton.py" "$network")"
  mkdir -p "$run_dir"
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
  echo "==> $network sandbox: $binary (evidence: $run_dir)"
  "$binary" sandbox --static-time \
    --ledger-api-port "$ledger" --admin-api-port "$admin" --json-api-port "$json" \
    --sequencer-public-port "$sequencer" --sequencer-admin-port "$seq_admin" --mediator-admin-port "$mediator" \
    --canton-port-file "$run_dir/ports.json" --log-file-name "$run_dir/canton.log" \
    --log-level-stdout WARN >"$run_dir/console.log" 2>&1 &
  CL_SANDBOX_PID=$!

  for ((attempt = 0; attempt < 120; attempt++)); do
    [[ -f "$run_dir/ports.json" ]] && break
    if ! kill -0 "$CL_SANDBOX_PID" 2>/dev/null; then
      tail -60 "$run_dir/console.log" >&2
      return 1
    fi
    sleep 1
  done
  if [[ ! -f "$run_dir/ports.json" ]]; then
    echo "Canton startup timed out: $run_dir" >&2
    # The caller has not registered a cleanup trap yet; do not leak the process.
    kill "$CL_SANDBOX_PID" 2>/dev/null || true
    wait "$CL_SANDBOX_PID" 2>/dev/null || true
    return 1
  fi

  CL_LEDGER_PORT="$ledger"
  CL_ADMIN_PORT="$admin"
  CL_JSON_PORT="$json"
  export CL_SANDBOX_PID CL_LEDGER_PORT CL_ADMIN_PORT CL_JSON_PORT
}
