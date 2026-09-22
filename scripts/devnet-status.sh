#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Compare the live DevNet Splice version against the pinned release in
# SPLICE_PIN. Informational only: this is not a compatibility gate, and it
# always exits 0 as long as it can reach and parse DevNet's /info endpoint.
# `just check-pin` and `just check-compatibility` are the actual gates.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pinned_ref="$(python3 -c 'import json; print(json.load(open("'"$ROOT"'/SPLICE_PIN"))["ref"])')"
info_url="$(python3 -c 'import json; print(json.load(open("'"$ROOT"'/fixtures/runtime-versions.json"))["devnet"]["info_url"])')"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 60 "$info_url" > "$body_file"; then
  echo "devnet-status: failed to reach $info_url" >&2
  exit 1
fi
devnet_version="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sv"]["version"])' < "$body_file")" || {
  echo "devnet-status: failed to parse .sv.version from $info_url" >&2
  exit 1
}

echo "SPLICE_PIN ref: $pinned_ref"
echo "DevNet Splice version: $devnet_version"
if [[ "$pinned_ref" == "$devnet_version" ]]; then
  echo "RESULT: MATCH"
else
  echo "RESULT: MISMATCH"
  echo "DevNet moving ahead of the pin is expected and does not invalidate the pinned build; see 'just check-pin' / 'just check-compatibility' for the actual gates."
fi
exit 0
