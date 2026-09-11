#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in python3 cargo cargo-build-sbf; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required for the Solana hash proof; see docs/runbook/hash-vectors.md." >&2
    exit 1
  }
done

python3 "$ROOT/scripts/generate-hash-vectors.py" --check
"$ROOT/scripts/build-solana.sh"
cd "$ROOT/contracts/solana"

echo "==> Solana SBF hash vectors in LiteSVM ($(rustc --version))"
cargo test --locked --test hash_vectors -- --nocapture
