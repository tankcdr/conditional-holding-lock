#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bring up the Splice localnet at the Mainnet release, then upload the
# unpublished conditional-lock DARs onto the app-provider participant.
#
#   ./scripts/localnet.sh              # up + wait + bootstrap
#   ./scripts/localnet.sh --no-bootstrap
#   ./scripts/localnet.sh --down       # stop, keep volumes
#   ./scripts/localnet.sh --clean      # stop and delete volumes
#
# The stack itself is Splice's own compose file, vendored verbatim under
# localnet-overrides/splice-<IMAGE_TAG>/ by scripts/localnet-sync.sh. This
# script contributes only the wait loops and the bootstrap.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/localnet-compose.sh
. "$ROOT/scripts/lib/localnet-compose.sh"

info() { printf '[INFO]  %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

DOWN=false
CLEAN=false
BOOTSTRAP=true
for arg in "$@"; do
  case "$arg" in
    --down) DOWN=true ;;
    --clean) CLEAN=true ;;
    --no-bootstrap) BOOTSTRAP=false ;;
    *) error "unknown argument: $arg"; exit 1 ;;
  esac
done

if $CLEAN; then
  localnet_compose down -v --remove-orphans
  info "localnet stopped and volumes removed"
  exit 0
fi
if $DOWN; then
  localnet_compose down --remove-orphans
  info "localnet stopped (volumes kept; use --clean to delete them)"
  exit 0
fi

localnet_env
localnet_check_container_names

info "starting Splice localnet ${IMAGE_TAG} (project ${LOCALNET_PROJECT}, network ${DOCKER_NETWORK:-localnet})"
info "tree: ${LOCALNET_DIR}"
localnet_compose up -d

# Readiness is proven against the app-provider node, the one this repository
# uploads to and runs the reference deployment against.
info "waiting for the app-provider participant JSON Ledger API on :3975"
for i in $(seq 1 120); do
  if curl -sf -o /dev/null http://localhost:3975/livez 2>/dev/null \
     || curl -s -o /dev/null -w '%{http_code}' http://localhost:3975/v2/version 2>/dev/null | grep -qE '^(200|401)$'; then
    info "app-provider participant is serving"
    break
  fi
  if [ "$i" -eq 120 ]; then
    error "the participant did not start serving in time"
    localnet_compose ps
    exit 1
  fi
  sleep 5
done

info "waiting for the app-provider validator on :3903 (SV onboarding takes a few minutes)"
for i in $(seq 1 240); do
  if curl -sf -o /dev/null http://localhost:3903/api/validator/readyz 2>/dev/null; then
    info "app-provider validator is ready"
    break
  fi
  if [ "$i" -eq 240 ]; then
    error "the validator did not become ready in time"
    localnet_compose ps
    exit 1
  fi
  sleep 5
done

if $BOOTSTRAP; then
  "$ROOT/scripts/localnet-bootstrap.sh"
fi

info "localnet ready."
info "  app-provider  JSON API http://localhost:3975   gRPC ledger localhost:3901   wallet http://wallet.localhost:3000"
info "  app-user      JSON API http://localhost:2975   gRPC ledger localhost:2901   wallet http://wallet.localhost:2000"
info "  sv            JSON API http://localhost:4975   gRPC ledger localhost:4901   scan   http://scan.localhost:4000"
info "Stop with ./scripts/localnet.sh --down"
