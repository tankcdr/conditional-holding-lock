#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Run the escrowed-DvP-with-dispute-window reference deployment
# (examples/devnet-escrow) against a real participant under wall-clock time,
# and record the resulting evidence.
#
# Usage: scripts/devnet-reference.sh [--network <localnet|devnet>] [--release <tag>]
#                                    [--dars <dir>] [--window <seconds>] [--manifest <path>]
#
# --network localnet (default): starts an isolated, wall-clock Canton sandbox
#   pinned to the testnet runtime (Canton 3.5.17) and runs against it.
# --network devnet: does not start anything. Requires LEDGER_JSON_API,
#   LEDGER_HOST, and LEDGER_PORT from the environment (LEDGER_TOKEN passed
#   through if set), and fails clearly, touching no network, if they are unset.
#
# --release <tag>: download the named GitHub release's DARs and manifest
#   instead of building locally.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
. "$ROOT/scripts/lib/sandbox.sh"
conditional_lock_java

EXAMPLE_DIR="$ROOT/examples/devnet-escrow"
EXAMPLE_DAR="$EXAMPLE_DIR/.daml/dist/conditional-lock-devnet-escrow-1.0.0.dar"

network="localnet"
release=""
dars_dir=""
window=20
manifest=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --network requires an argument" >&2; exit 1; }
      network="$2"; shift 2 ;;
    --release)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --release requires an argument" >&2; exit 1; }
      release="$2"; shift 2 ;;
    --dars)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --dars requires an argument" >&2; exit 1; }
      dars_dir="$2"; shift 2 ;;
    --window)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --window requires an argument" >&2; exit 1; }
      window="$2"; shift 2 ;;
    --manifest)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --manifest requires an argument" >&2; exit 1; }
      manifest="$2"; shift 2 ;;
    *)
      echo "devnet-reference: unknown argument: $1" >&2
      exit 1 ;;
  esac
done

case "$network" in
  localnet|devnet) ;;
  *) echo "devnet-reference: --network must be localnet or devnet, got: $network" >&2; exit 1 ;;
esac

# Fail fast, before touching any network, if devnet mode is missing what it needs.
if [[ "$network" == "devnet" ]]; then
  if [[ -z "${LEDGER_JSON_API:-}" ]]; then
    echo "devnet-reference: --network devnet requires LEDGER_JSON_API (and LEDGER_HOST/LEDGER_PORT) in the environment; LEDGER_JSON_API is unset" >&2
    exit 1
  fi
  if [[ -z "${LEDGER_HOST:-}" || -z "${LEDGER_PORT:-}" ]]; then
    echo "devnet-reference: --network devnet requires LEDGER_JSON_API, LEDGER_HOST, and LEDGER_PORT in the environment; LEDGER_HOST/LEDGER_PORT is unset" >&2
    exit 1
  fi
fi

run_dir="$(mktemp -d "$ROOT/.localnet/devnet-reference-$network.XXXXXX")"
staging="$run_dir/dars"
mkdir -p "$staging"

if [[ -n "$release" ]]; then
  echo "==> downloading release $release DARs from tankcdr/conditional-holding-lock"
  gh release download "$release" --repo tankcdr/conditional-holding-lock --pattern '*.dar' --dir "$staging"
  gh release download "$release" --repo tankcdr/conditional-holding-lock --pattern 'conditional-lock-release.json' --dir "$staging"
  if [[ -z "$manifest" ]]; then
    manifest="$staging/conditional-lock-release.json"
  fi
  # The release only carries the three first-party DARs (they are what the
  # manifest tracks); the Splice dependency DARs are not release artifacts
  # and still have to come from a local fetch.
  "$ROOT/scripts/fetch-dars.sh"
  cp "$ROOT/.dars/"*.dar "$staging/"
elif [[ -n "$dars_dir" ]]; then
  echo "==> using DARs from $dars_dir"
  cp "$dars_dir"/*.dar "$staging/"
else
  echo "==> building local first-party packages"
  "$ROOT/scripts/build-dars.sh"
  cp "$ROOT/.dars/"*.dar "$staging/"
  cp "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/splice-api-token-conditional-lock-v1-1.0.0.dar" "$staging/"
  cp "$ROOT/packages/conditional-lock-utils/.daml/dist/conditional-lock-utils-1.0.0.dar" "$staging/"
  cp "$ROOT/packages/conditional-lock-test-token/.daml/dist/conditional-lock-test-token-1.0.0.dar" "$staging/"
fi

echo "==> building examples/devnet-escrow"
rm -rf "$EXAMPLE_DIR/dars"
mkdir -p "$EXAMPLE_DIR/dars"
cp "$staging/splice-api-token-metadata-v1-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/splice-api-token-holding-v2-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/splice-api-token-conditional-lock-v1-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/splice-test-token-v2-1.0.1.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/conditional-lock-utils-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/conditional-lock-test-token-1.0.0.dar" "$EXAMPLE_DIR/dars/"
( cd "$EXAMPLE_DIR" && dpm build )

sandbox_runtime=""
if [[ "$network" == "localnet" ]]; then
  # sandbox.sh registers the kill/wait traps itself, before its startup wait.
  # The sandbox network is testnet (Canton 3.5.17), the pinned runtime we have
  # a checksum for; the evidence's network_runtime stays "localnet".
  CL_SANDBOX_WALL_CLOCK=1 conditional_lock_sandbox_start testnet "$run_dir"
  sandbox_runtime="testnet"
  export LEDGER_JSON_API="http://127.0.0.1:$CL_JSON_PORT"
  export LEDGER_HOST=127.0.0.1
  export LEDGER_PORT="$CL_LEDGER_PORT"
fi

echo "==> deploying first-party release DARs"
manifest_args=()
if [[ -n "$manifest" ]]; then manifest_args=(--manifest "$manifest"); fi
"$ROOT/scripts/deploy-dars.sh" "${manifest_args[@]}" \
  "$staging/splice-api-token-conditional-lock-v1-1.0.0.dar" \
  "$staging/conditional-lock-utils-1.0.0.dar" \
  "$staging/conditional-lock-test-token-1.0.0.dar"

echo "==> deploying Splice dependency DARs and the example DAR"
"$ROOT/scripts/deploy-dars.sh" \
  "$staging/splice-api-token-metadata-v1-1.0.0.dar" \
  "$staging/splice-api-token-holding-v2-1.0.0.dar" \
  "$staging/splice-test-token-v2-1.0.1.dar" \
  "$EXAMPLE_DAR"

echo "$window" > "$run_dir/input.json"

echo "==> running the reference deployment (window=${window}s, wall-clock time)"
dpm script --dar "$EXAMPLE_DAR" \
  --script-name EscrowedDvpDevNet:referenceDeployment \
  --ledger-host "$LEDGER_HOST" --ledger-port "$LEDGER_PORT" \
  --input-file "$run_dir/input.json" --output-file "$run_dir/script-output.json"

curl -fsS "$LEDGER_JSON_API/v2/version" > "$run_dir/ledger-version.json"

# Ledger update IDs: Daml Script returns choice results, not update IDs, and
# fetching them from the JSON Ledger API's /v2/updates route is not a
# one-attempt operation against an unfamiliar participant. record-reference-proof.py
# ships the contract IDs the script itself returned and records that honestly.

record_args=(--network "$network" --run-dir "$run_dir" --dar-dir "$staging")
if [[ -n "$release" ]]; then record_args+=(--release "$release"); fi
if [[ -n "$sandbox_runtime" ]]; then record_args+=(--sandbox-runtime "$sandbox_runtime"); fi

python3 "$ROOT/scripts/record-reference-proof.py" "${record_args[@]}"

evidence_path="$ROOT/docs/runbook/${network}-reference-evidence.json"
echo "PASS $network; evidence: $evidence_path"
