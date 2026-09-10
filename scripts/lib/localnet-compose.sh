#!/usr/bin/env bash
# Single compose invocation for localnet.
set -euo pipefail
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

localnet_compose() {
  if [ ! -d "$_ROOT/localnet/quickstart" ]; then
    git -C "$_ROOT" submodule update --init --depth 1 localnet
  fi
  if [ ! -f "$_ROOT/.env.localnet" ]; then
    cp "$_ROOT/.env.localnet.example" "$_ROOT/.env.localnet"
  fi
  docker compose \
    -f "$_ROOT/docker-compose.localnet.yml" \
    --env-file "$_ROOT/.env.localnet" \
    --project-directory "$_ROOT" \
    "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  localnet_compose "$@"
fi
