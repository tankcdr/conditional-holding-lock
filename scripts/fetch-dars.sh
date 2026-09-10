#!/usr/bin/env bash
# Download published Splice token-standard DARs into gitignored .dars/.
# These are compile-time data-dependencies, not Splice source.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DARS="$ROOT/.dars"
REF="${SPLICE_DARS_REF:-main}"
BASE="https://raw.githubusercontent.com/canton-network/splice/${REF}/daml/dars"

needed=(
  splice-api-token-metadata-v1-1.0.0.dar
  splice-api-token-holding-v2-1.0.0.dar
)

mkdir -p "$DARS"
for f in "${needed[@]}"; do
  dest="$DARS/$f"
  if [ -f "$dest" ]; then
    echo "have $f"
    continue
  fi
  echo "fetch $f"
  curl -fsSL "$BASE/$f" -o "$dest"
done
echo "dars in $DARS"
