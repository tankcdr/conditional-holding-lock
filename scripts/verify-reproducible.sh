#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Rebuild all first-party Daml packages twice from clean and confirm the
# resulting package IDs reproduce exactly.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
conditional_lock_java

PINNED_INTERFACE_ID="ff9cd0184bcd2f3a88b0c8c1c74bcff94e49c7ff00c04e144b33f26f7266811e"

package_list="$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
import dar_identity
for pkg, _attached in dar_identity.PACKAGES:
    print(pkg, dar_identity.built_dar_path(pkg))
")"

ids() {
  local pkg dar pkg_id re='^[0-9a-f]{64}$'
  while read -r pkg dar; do
    [[ -f "$dar" ]] || { echo "verify-reproducible: DAR for $pkg not found at $dar" >&2; exit 1; }
    pkg_id="$(dpm inspect-dar --json "$dar" | jq -r '.main_package_id')"
    if ! [[ "$pkg_id" =~ $re ]]; then
      echo "verify-reproducible: package ID for $pkg is not a 64-hex package ID: '$pkg_id'" >&2
      exit 1
    fi
    echo "$pkg $pkg_id"
  done <<< "$package_list"
}

rebuild() {
  rm -rf "$ROOT"/packages/*/.daml
  "$ROOT/scripts/build-dars.sh"
}

first="$(mktemp -d)"
second="$(mktemp -d)"
trap 'rm -rf "$first" "$second"' EXIT

rebuild
ids > "$first/ids.txt"

rebuild
ids > "$second/ids.txt"

if ! diff "$first/ids.txt" "$second/ids.txt"; then
  echo "Package IDs did not reproduce across two clean builds" >&2
  exit 1
fi

interface_id="$(awk -v pkg="splice-api-token-conditional-lock-v1" '$1 == pkg { print $2 }' "$second/ids.txt")"
if [[ "$interface_id" != "$PINNED_INTERFACE_ID" ]]; then
  echo "splice-api-token-conditional-lock-v1 package ID is $interface_id, expected pinned $PINNED_INTERFACE_ID (see daml/dars.lock on the proposed Splice branch, PR 7294); it changes only with a deliberate interface revision, which must update both pins." >&2
  exit 1
fi

echo "OK: package IDs reproduce"
