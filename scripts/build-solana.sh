#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v cargo-build-sbf >/dev/null 2>&1 || {
  echo 'Solana SBF build tools are required; see docs/runbook/hash-vectors.md.' >&2
  exit 1
}
cd "$ROOT/contracts/solana"

echo "==> Build Solana hash program ($(cargo-build-sbf --version | head -1))"
# Pin the SBF compiler separately from the host Rust toolchain. Keep all output
# under the repository's ignored target/ directory, including generated keys.
cargo-build-sbf --tools-version v1.52 --arch v0 \
  --sbf-out-dir "$PWD/target/deploy" -- --locked
