#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The single compose invocation for the localnet. It runs Splice's own
# compose files, vendored verbatim under localnet-overrides/splice-<IMAGE_TAG>/,
# exactly as Splice's docs/src/app_dev/testing/localnet.rst prescribes:
#
#   docker compose --env-file $LOCALNET_DIR/compose.env \
#                  --env-file $LOCALNET_DIR/env/common.env \
#                  -f $LOCALNET_DIR/compose.yaml \
#                  -f $LOCALNET_DIR/resource-constraints.yaml \
#                  --profile sv --profile app-provider --profile app-user ...
#
# The one file that is ours is localnet-overrides/conditional-lock.compose.yaml,
# layered last; it pins the app-provider participant's admin token. See that
# file for why. The vendored tree itself is never edited.
#
# Our own settings reach compose through the process environment, not through a
# third --env-file. That ordering matters: compose.env derives values from each
# other (LOCALNET_ENV_DIR from LOCALNET_DIR, PARTY_HINT from DOCKER_NETWORK),
# and a later --env-file would be read after those defaults were already
# resolved. Sourcing .env.localnet into the environment first makes compose.env's
# ${VAR:-default} forms pick our values up.
set -euo pipefail
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Container names in Splice's compose.yaml are fixed (canton, splice, postgres,
# nginx) and are NOT scoped by the compose project name, so another localnet on
# this machine using the same upstream file would collide. Fail with a message
# that says which container, instead of a compose error about a name in use.
localnet_check_container_names() {
  local ours existing name
  ours="$(docker ps -a --filter "label=com.docker.compose.project=${LOCALNET_PROJECT}" --format '{{.Names}}' 2>/dev/null || true)"
  for name in canton splice postgres nginx swagger-ui multi-sync-startup multi-sync-ready; do
    existing="$(docker ps -a --filter "name=^/${name}$" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "$existing" ] && ! printf '%s\n' "$ours" | grep -qx "$name"; then
      printf '[ERROR] a container named "%s" already exists and is not part of compose project "%s".\n' \
        "$name" "${LOCALNET_PROJECT}" >&2
      printf '        Splice'"'"'s localnet compose file uses fixed container names. Stop the other\n' >&2
      printf '        stack (docker rm -f %s) before starting this one.\n' "$name" >&2
      return 1
    fi
  done
}

localnet_env() {
  if [ ! -f "$_ROOT/.env.localnet" ]; then
    cp "$_ROOT/.env.localnet.example" "$_ROOT/.env.localnet"
    printf '[INFO]  wrote .env.localnet from .env.localnet.example\n' >&2
  fi
  # Export every assignment in .env.localnet into this shell's environment.
  set -a
  # shellcheck disable=SC1091
  . "$_ROOT/.env.localnet"
  set +a

  : "${IMAGE_TAG:?.env.localnet must set IMAGE_TAG (the Splice release tag)}"
  : "${PARTY_HINT:?.env.localnet must set PARTY_HINT}"

  # compose.yaml's volume sources are ${LOCALNET_DIR}/... and are resolved
  # against the compose project directory. Make the path absolute so the driver
  # works from any cwd and does not depend on --project-directory.
  LOCALNET_DIR="${LOCALNET_DIR:-./localnet-overrides/splice-$IMAGE_TAG}"
  case "$LOCALNET_DIR" in
    /*) ;;
    *) LOCALNET_DIR="$_ROOT/${LOCALNET_DIR#./}" ;;
  esac
  export LOCALNET_DIR
  export LOCALNET_ENV_DIR="${LOCALNET_ENV_DIR:-$LOCALNET_DIR/env}"

  if [ ! -f "$LOCALNET_DIR/compose.yaml" ]; then
    printf '[ERROR] %s/compose.yaml is missing. Run ./scripts/localnet-sync.sh to materialize\n' "$LOCALNET_DIR" >&2
    printf '        the Splice %s localnet tree into localnet-overrides/.\n' "$IMAGE_TAG" >&2
    return 1
  fi

  LOCALNET_PROJECT="${LOCALNET_PROJECT:-conditional-lock-localnet}"
  export LOCALNET_PROJECT
}

localnet_compose() {
  localnet_env
  docker compose \
    --project-name "$LOCALNET_PROJECT" \
    --project-directory "$LOCALNET_DIR" \
    --env-file "$LOCALNET_DIR/compose.env" \
    --env-file "$LOCALNET_DIR/env/common.env" \
    -f "$LOCALNET_DIR/compose.yaml" \
    -f "$LOCALNET_DIR/resource-constraints.yaml" \
    -f "$_ROOT/localnet-overrides/conditional-lock.compose.yaml" \
    --profile sv \
    --profile app-provider \
    --profile app-user \
    "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  localnet_compose "$@"
fi
