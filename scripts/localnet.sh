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

# Both wait loops probe the app-provider node, the one this repository uploads
# to and proves against. Derive their URLs from LEDGER_JSON_API rather than
# writing :3975 and :3903 down a second time, so changing the port in
# .env.localnet cannot leave this script polling the old one. Splice's port
# pattern is <node><suffix>: 975 is the participant JSON API, 903 the validator
# admin API, and the leading digit selects the node (3 = app-provider).
JSON_BASE="${LEDGER_JSON_API:?.env.localnet must set LEDGER_JSON_API}"
JSON_BASE="${JSON_BASE%/}"
_json_port="${JSON_BASE##*:}"
case "$_json_port" in
  *975) VALIDATOR_BASE="${JSON_BASE%:*}:${_json_port%975}903" ;;
  *) VALIDATOR_BASE="" ;;
esac

info "starting Splice localnet ${IMAGE_TAG} (project ${LOCALNET_PROJECT}, network ${DOCKER_NETWORK:-localnet})"
info "tree: ${LOCALNET_DIR}"
localnet_compose up -d

# Readiness is proven against the app-provider node, the one this repository
# uploads to and runs the reference deployment against.
info "waiting for the app-provider participant JSON Ledger API at $JSON_BASE"
for i in $(seq 1 120); do
  if curl -sf -o /dev/null "$JSON_BASE/livez" 2>/dev/null \
     || curl -s -o /dev/null -w '%{http_code}' "$JSON_BASE/v2/version" 2>/dev/null | grep -qE '^(200|401)$'; then
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

if [ -z "$VALIDATOR_BASE" ]; then
  info "LEDGER_JSON_API port is not a Splice <node>975 port; skipping the validator wait"
fi
info "waiting for the app-provider validator at ${VALIDATOR_BASE:-<skipped>} (SV onboarding takes a few minutes)"
for i in $(seq 1 240); do
  if [ -z "$VALIDATOR_BASE" ] || curl -sf -o /dev/null "$VALIDATOR_BASE/api/validator/readyz" 2>/dev/null; then
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
