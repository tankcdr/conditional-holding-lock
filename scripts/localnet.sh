#!/usr/bin/env bash
# Bring up Splice localnet, then upload unpublished CIP DARs.
#
#   ./scripts/localnet.sh           # up + wait + bootstrap
#   ./scripts/localnet.sh --down
#   ./scripts/localnet.sh --clean
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/localnet-compose.sh
. "$ROOT/scripts/lib/localnet-compose.sh"

info() { printf '[INFO]  %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

DOWN=false
CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --down) DOWN=true ;;
    --clean) CLEAN=true ;;
  esac
done

if $CLEAN; then
  localnet_compose down -v
  info "localnet volumes removed"
  exit 0
fi
if $DOWN; then
  localnet_compose down
  exit 0
fi

if [ ! -d localnet/quickstart ]; then
  info "initializing localnet submodule (cn-quickstart)"
  git submodule update --init --depth 1 localnet
fi
if [ ! -f .env.localnet ]; then
  cp .env.localnet.example .env.localnet
  info "wrote .env.localnet from example"
fi

info "starting canton + splice"
localnet_compose up -d

info "waiting for canton JSON API on :3975"
for i in $(seq 1 90); do
  if curl -sf http://localhost:3975/readyz >/dev/null 2>&1 \
     || curl -sf http://localhost:3975/v2/version >/dev/null 2>&1; then
    info "canton is up"
    break
  fi
  if [ "$i" -eq 90 ]; then
    error "canton did not become ready in time"
    localnet_compose ps
    exit 1
  fi
  sleep 5
done

info "waiting for splice"
for i in $(seq 1 120); do
  if curl -sf http://localhost:3903/api/validator/readyz >/dev/null 2>&1; then
    info "splice validator is up"
    break
  fi
  if [ "$i" -eq 120 ]; then
    error "splice did not become ready in time"
    localnet_compose ps
    exit 1
  fi
  sleep 5
done

"$ROOT/scripts/localnet-bootstrap.sh"
info "localnet ready. JSON API: http://localhost:3975  wallet: http://localhost:2000  scan: http://localhost:4000"
