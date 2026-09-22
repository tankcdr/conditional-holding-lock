#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Upload DARs to a participant's JSON Ledger API. The single /v2/packages
# upload path in this repository.
#
# Usage: scripts/deploy-dars.sh [--manifest <path>] <dar> [<dar> ...]
#
# Env:
#   LEDGER_JSON_API   Participant JSON Ledger API base URL (required),
#                      e.g. http://127.0.0.1:7575 or https://...
#   LEDGER_TOKEN       Bearer token (optional)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LEDGER_JSON_API:?set LEDGER_JSON_API to the participant JSON Ledger API base URL}"
BASE="${LEDGER_JSON_API%/}"

manifest=""
darfiles=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || { echo "deploy-dars: --manifest requires a path" >&2; exit 1; }
      manifest="$2"
      shift 2
      ;;
    *)
      darfiles+=("$1")
      shift
      ;;
  esac
done

if [[ ${#darfiles[@]} -eq 0 ]]; then
  echo "deploy-dars: at least one DAR argument is required" >&2
  echo "Usage: scripts/deploy-dars.sh [--manifest <path>] <dar> [<dar> ...]" >&2
  exit 1
fi

for dar in "${darfiles[@]}"; do
  if [[ ! -e "$dar" ]]; then
    echo "deploy-dars: DAR not found: $dar" >&2
    exit 1
  fi
done

# NEVER echo, log, or print LEDGER_TOKEN or the Authorization header; do not
# use set -x in this script.
AUTH=()
if [[ -n "${LEDGER_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${LEDGER_TOKEN}")
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

version_status="$(curl -sS -o "$body_file" -w '%{http_code}' \
  --connect-timeout 15 --max-time 60 \
  ${AUTH[@]+"${AUTH[@]}"} \
  "$BASE/v2/version")" || {
  echo "deploy-dars: failed to reach $BASE/v2/version" >&2
  exit 1
}
case "$version_status" in
  2??) ;;
  *)
    echo "deploy-dars: probe of $BASE/v2/version failed with status $version_status" >&2
    head -c 200 "$body_file" >&2
    echo >&2
    exit 1
    ;;
esac
ledger_version="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' < "$body_file")"

if [[ -n "$manifest" ]]; then
  if [[ ! -f "$manifest" ]]; then
    echo "deploy-dars: manifest not found: $manifest" >&2
    exit 1
  fi
  for dar in "${darfiles[@]}"; do
    base_name="$(basename "$dar")"
    result="$(python3 -c '
import hashlib, json, sys
manifest = json.load(open(sys.argv[1]))
name = sys.argv[2]
dar_path = sys.argv[3]
for pkg in manifest["packages"]:
    if pkg["file"] == name:
        observed = hashlib.sha256(open(dar_path, "rb").read()).hexdigest()
        print(pkg["dar_sha256"])
        print(observed)
        break
' "$manifest" "$base_name" "$dar")"
    if [[ -z "$result" ]]; then
      echo "deploy-dars: $base_name is not listed in manifest $manifest" >&2
      exit 1
    fi
    expected_digest="$(echo "$result" | sed -n '1p')"
    observed_digest="$(echo "$result" | sed -n '2p')"
    if [[ "$observed_digest" != "$expected_digest" ]]; then
      echo "deploy-dars: SHA-256 mismatch for $base_name: expected $expected_digest, observed $observed_digest" >&2
      exit 1
    fi
  done
fi

echo "deploy-dars: ledger version $ledger_version at $BASE"

for dar in "${darfiles[@]}"; do
  echo "==> uploading $dar"
  status="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -X POST "$BASE/v2/packages" \
    -H "Content-Type: application/octet-stream" \
    ${AUTH[@]+"${AUTH[@]}"} \
    --data-binary @"$dar")"
  case "$status" in
    2??|409) ;;
    *)
      echo "deploy-dars: upload of $dar failed with status $status" >&2
      head -c 200 "$body_file" >&2
      echo >&2
      exit 1
      ;;
  esac
done

echo "deploy-dars: ledger version $ledger_version at $BASE"
