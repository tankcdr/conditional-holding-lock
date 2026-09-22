#!/usr/bin/env bash
# Fetch Splice interface DARs, then build first-party packages against them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

"$ROOT/scripts/fetch-dars.sh"

# The package list lives in scripts/lib/dar_identity.py (PACKAGES), which is
# also what the manifest, the evidence, and the reproducibility check read, so
# a package can never be built but left out of the release.
packages=()
while IFS= read -r line; do packages+=("$line"); done < <(python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
import dar_identity
for pkg, _attached in dar_identity.PACKAGES:
    print('packages/' + pkg)
")

for pkg in "${packages[@]}"; do
  echo "==> dpm build $pkg"
  ( cd "$ROOT/$pkg" && dpm build )
done
echo "OK: first-party packages built"
