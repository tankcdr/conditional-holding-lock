#!/usr/bin/env bash
# Fetch Splice interface DARs, then build first-party packages against them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

"$ROOT/scripts/fetch-dars.sh"

packages=(
  packages/splice-api-token-conditional-lock-v1
  packages/conditional-lock-test
)

for pkg in "${packages[@]}"; do
  echo "==> dpm build $pkg"
  ( cd "$ROOT/$pkg" && dpm build )
done
echo "OK: first-party packages built"
