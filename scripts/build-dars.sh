#!/usr/bin/env bash
# Fetch Splice interface DARs, then build first-party packages against them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

"$ROOT/scripts/fetch-dars.sh"

# Build order. The release-identity list lives in scripts/lib/dar_identity.py
# (PACKAGES); keep the two in step when adding a package.
packages=(
  packages/splice-api-token-conditional-lock-v1
  packages/conditional-lock-utils
  packages/conditional-lock-test-token
  packages/conditional-lock-test
)

for pkg in "${packages[@]}"; do
  echo "==> dpm build $pkg"
  ( cd "$ROOT/$pkg" && dpm build )
done
echo "OK: first-party packages built"
