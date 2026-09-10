#!/usr/bin/env bash
# Build token-standard packages in dependency order and symlink *-current.dar
# names that Splice daml.yaml files expect. Outside Splice's sbt/Nix, this is
# how local DAR data-dependencies resolve.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$ROOT/splice/token-standard"
export PATH="${HOME}/.dpm/bin:${PATH}"

packages=(
  splice-api-token-metadata-v1
  splice-api-token-holding-v1
  splice-api-token-holding-v2
  splice-api-token-transfer-instruction-v1
  splice-api-token-transfer-instruction-v2
  splice-api-token-allocation-v1
  splice-api-token-allocation-v2
  splice-api-token-allocation-instruction-v1
  splice-api-token-allocation-instruction-v2
  splice-api-token-allocation-request-v1
  splice-api-token-allocation-request-v2
  splice-api-token-transfer-events-v2
  splice-api-token-conditional-lock-v1
  splice-token-standard-utils
  examples/splice-test-token-v2
  examples/splice-test-token-conditional-lock-test
)

symlink_current() {
  local dir="$1"
  local name
  name="$(awk '/^name:/{print $2; exit}' "$dir/daml.yaml")"
  local dist="$dir/.daml/dist"
  local dar
  dar="$(find "$dist" -maxdepth 1 -name "${name}-*.dar" ! -name '*-current.dar' | head -n 1)"
  if [[ -z "${dar}" ]]; then
    echo "error: no versioned DAR for $name in $dist" >&2
    return 1
  fi
  ln -sfn "$(basename "$dar")" "$dist/${name}-current.dar"
  echo "    -> $(basename "$dar")  =>  ${name}-current.dar"
}

for pkg in "${packages[@]}"; do
  echo "==> dpm build $pkg"
  ( cd "$TS/$pkg" && dpm build )
  symlink_current "$TS/$pkg"
done

echo "OK: all packages built"
