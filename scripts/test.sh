#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

if [[ -z "${JAVA_HOME:-}" ]]; then
  if /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
fi
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"

"$ROOT/scripts/build-dars.sh"

echo "==> Daml Script (Java $(java -version 2>&1 | head -1))"
( cd "$ROOT/packages/conditional-lock-test" && dpm test )

if command -v forge >/dev/null 2>&1; then
  echo "==> EVM hash vectors"
  if [[ ! -f "$ROOT/contracts/evm/lib/forge-std/src/Test.sol" ]]; then
    git clone --depth 1 https://github.com/foundry-rs/forge-std "$ROOT/contracts/evm/lib/forge-std"
    echo 'forge-std/=lib/forge-std/src/' > "$ROOT/contracts/evm/remappings.txt"
  fi
  ( cd "$ROOT/contracts/evm" && forge test -vv )
else
  echo "skip forge (not installed)"
fi
