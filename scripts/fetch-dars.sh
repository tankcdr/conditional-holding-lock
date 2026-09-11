#!/usr/bin/env bash
# Fetch immutable, checksum-verified published DARs; never vendor Splice source.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/fetch-dars.py"
