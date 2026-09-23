#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prove the DvP evidence recorder rejects a tampered run file. Copies the last
# integration run to a temporary directory, corrupts one claimed field at a
# time, and requires scripts/record-reference-proof.py to exit non-zero for
# each. Runs against integration/.run, so it needs a completed
# `pnpm test:integration` first. Never touches docs/runbook: the recorder's
# gates fire before it writes, and each mutation is expected to fail a gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$ROOT/integration/.run"
[[ -f "$RUN_DIR/dvp-run.json" ]] || { echo "dvp-evidence-tamper: no $RUN_DIR/dvp-run.json; run pnpm test:integration first" >&2; exit 2; }
tag="${1:-$(grep -E '^IMAGE_TAG=' "$ROOT/.env.localnet" 2>/dev/null | cut -d= -f2 || true)}"
[[ -n "$tag" ]] || { echo "dvp-evidence-tamper: no IMAGE_TAG; pass the Splice tag as the first argument" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# name | python expression applied to the run dict d
mutations=(
  'returned owner is a third party|d["expiry"]["returned_owner"] = "third-party::1220" + "ab" * 32'
  'returned owner is the delivery receiver|d["expiry"]["returned_owner"] = d["settlement"]["delivery"]["receiver"]'
  'rejection text is the bare constant|d["expiry"]["enact_rejection"] = "no alternative is satisfied"'
  'rejection text lacks the guard phrase|d["expiry"]["enact_rejection"] = "POST http://x/v2/commands/submit-and-wait-for-transaction -> 400\nsomething else"'
)

failures=0
for entry in "${mutations[@]}"; do
  name="${entry%%|*}"; expr="${entry#*|}"
  rm -rf "$tmp/run"; cp -R "$RUN_DIR" "$tmp/run"
  python3 - "$tmp/run/dvp-run.json" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(expr)
json.dump(d, open(path, "w"), indent=2)
PY
  if python3 "$ROOT/scripts/record-reference-proof.py" --kind dvp --network localnet-mainnet \
       --runtime-tag "$tag" --run-dir "$tmp/run" >"$tmp/out.log" 2>&1; then
    echo "FAIL  recorder accepted a run where $name" >&2
    failures=$((failures + 1))
  else
    echo "ok    recorder rejected: $name ($(tail -1 "$tmp/out.log" | cut -c1-110))"
  fi
done
# Acceptance of the untampered run is proven by the recorder call that precedes
# this script in `just test-integration-evidence`; it is not repeated here so the
# committed evidence file is written exactly once per run.
[[ "$failures" -eq 0 ]] || { echo "dvp-evidence-tamper: $failures failure(s)" >&2; exit 1; }
echo "OK: the DvP evidence gates reject every tampered field"
