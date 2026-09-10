#!/usr/bin/env bash
# Initialize the Splice submodule as a sparse, blobless checkout of token-standard.
# Splice is a large monorepo; we only need token-standard to build this CIP.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git submodule update --init --filter=blob:none --checkout splice
git -C splice sparse-checkout init --cone
git -C splice sparse-checkout set token-standard
git -C splice checkout cip-conditional-holding-lock
echo "splice @ $(git -C splice rev-parse --short HEAD) (sparse: token-standard)"
