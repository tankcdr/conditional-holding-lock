#!/usr/bin/env bash
# cn-quickstart only. Splice is not a submodule of this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git submodule update --init --depth 1 localnet
echo "localnet @ $(git -C localnet rev-parse --short HEAD) (cn-quickstart)"
