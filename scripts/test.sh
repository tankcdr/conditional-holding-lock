#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"

if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ -d "${HOME}/Library/Caches/Coursier/arc/https/github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%252B8/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.20_8.tar.gz/jdk-17.0.20+8/Contents/Home" ]]; then
    export JAVA_HOME="${HOME}/Library/Caches/Coursier/arc/https/github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%252B8/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.20_8.tar.gz/jdk-17.0.20+8/Contents/Home"
  elif /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
fi
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"

# shellcheck source=lib/splice-dir.sh
. "$ROOT/scripts/lib/splice-dir.sh"
require_splice

echo "==> Daml Script confirmation tests (Java $(java -version 2>&1 | head -1))"
( cd "$SPLICE_DIR/token-standard/examples/splice-test-token-conditional-lock-test" && dpm test )

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
