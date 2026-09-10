#!/usr/bin/env bash
# Sparse, blobless clone of the CIP fork. Output is gitignored; it is not part
# of this repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/splice-dir.sh
. "$ROOT/scripts/lib/splice-dir.sh"

if [ -d "$SPLICE_DIR/.git" ] || [ -f "$SPLICE_DIR/.git" ]; then
  echo "already a git checkout: $SPLICE_DIR"
  git -C "$SPLICE_DIR" checkout "$SPLICE_BRANCH"
  git -C "$SPLICE_DIR" pull --ff-only || true
  exit 0
fi
if [ -e "$SPLICE_DIR" ]; then
  echo "error: $SPLICE_DIR exists and is not a git checkout" >&2
  exit 1
fi

git clone --filter=blob:none --sparse -b "$SPLICE_BRANCH" "$SPLICE_FORK" "$SPLICE_DIR"
git -C "$SPLICE_DIR" sparse-checkout set token-standard
echo "splice @ $(git -C "$SPLICE_DIR" rev-parse --short HEAD) in $SPLICE_DIR"
