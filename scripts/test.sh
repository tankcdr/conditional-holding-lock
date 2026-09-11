#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

# Preserve the stale-JAVA_HOME workaround and select the supported JDK.
. "$ROOT/scripts/lib/java.sh"
conditional_lock_java

command -v forge >/dev/null 2>&1 || { echo 'Foundry is required for the EVM hash proof.' >&2; exit 1; }
python3 "$ROOT/scripts/generate-hash-vectors.py" --check

"$ROOT/scripts/build-dars.sh"

echo "==> Daml Script (Java $(java -version 2>&1 | head -1))"
( cd "$ROOT/packages/conditional-lock-test" && dpm test )

echo "==> EVM hash vectors"
( cd "$ROOT/contracts/evm" && forge test -vv )
