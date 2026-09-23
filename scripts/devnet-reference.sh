#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Run the escrowed-DvP-with-dispute-window reference deployment
# (examples/devnet-escrow) against a real participant under wall-clock time,
# and record the resulting evidence.
#
# Usage: scripts/devnet-reference.sh [--network <localnet|localnet-mainnet|devnet>]
#                                    [--release <tag>] [--dars <dir>]
#                                    [--window <seconds>] [--manifest <path>]
#
# --network localnet (default): starts an isolated, wall-clock Canton sandbox
#   pinned to the testnet runtime (Canton 3.5.17) and runs against it.
# --network localnet-mainnet: the Docker Splice localnet at the Mainnet release
#   (./scripts/localnet.sh), i.e. a real participant with a real synchronizer
#   rather than a sandbox. Takes the external-participant path below: it starts
#   nothing and requires LEDGER_JSON_API, LEDGER_HOST, LEDGER_PORT, and (because
#   the localnet runs the auth-on profiles) LEDGER_TOKEN, all of which
#   `just localnet-prove` supplies from .env.localnet and
#   scripts/lib/localnet_token.py. Evidence is written per Splice image tag,
#   which is read from .env.localnet's IMAGE_TAG or from --runtime-tag.
# --network devnet: does not start anything. Requires LEDGER_JSON_API,
#   LEDGER_HOST, and LEDGER_PORT from the environment. If LEDGER_TOKEN is also
#   set, it is written to a mode-600 temp file and passed to `dpm script` as
#   --access-token-file (dpm wants the bare token there), and a second
#   mode-600 temp file holding the full "Authorization: Bearer <token>" header
#   line is passed to curl's /v2/version probe via `-H @file`, so the token
#   never appears in argv/`ps`. It is never echoed, logged, or written into
#   the evidence. Fails clearly, touching no network and starting no sandbox,
#   if LEDGER_JSON_API, LEDGER_HOST, or LEDGER_PORT are unset.
#   LEDGER_TLS=1 and LEDGER_CACRT=<path>: opt-in, pure passthrough to `dpm
#   script` as --tls / --cacrt <path> for a participant whose gRPC Ledger API
#   is TLS-terminated. Not inferred from LEDGER_JSON_API's scheme, since the
#   JSON API and the gRPC Ledger API are separate endpoints that can differ
#   in TLS termination. UNTESTED in this environment: there is no participant
#   here to exercise this path against, written but not exercised.
#
# --release <tag>: download the named GitHub release's DARs and manifest
#   instead of building locally.
#
# --window <seconds>: dispute window for the settle/award reference script
#   (default 20). Must be at least 15: the settle path needs headroom for
#   five submissions to complete before the deadline, and wall-clock latency
#   on a real participant is not the ~2s observed locally.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.dpm/bin:${PATH}"
. "$ROOT/scripts/lib/java.sh"
. "$ROOT/scripts/lib/sandbox.sh"
conditional_lock_java

EXAMPLE_DIR="$ROOT/examples/devnet-escrow"
EXAMPLE_DAR="$EXAMPLE_DIR/.daml/dist/conditional-lock-devnet-escrow-1.0.0.dar"

# The three first-party release DAR filenames, from dar_identity.py's own
# PACKAGES tuple, so a version bump there does not have to be echoed here.
# The six Splice dependency DAR names below still come from SPLICE_PIN's
# "packages" list, but that list carries no per-example selection, so which
# three of the six this example needs stays a literal list.
read -r CL_TOKEN_DAR CL_UTILS_DAR CL_TEST_TOKEN_DAR < <(python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/lib')
import dar_identity
names = [dar_identity.built_dar_path(p).name for p, attached in dar_identity.PACKAGES if attached]
print(*names)
")

network="localnet"
release=""
dars_dir=""
window=20
manifest=""
runtime_tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --network requires an argument" >&2; exit 1; }
      network="$2"; shift 2 ;;
    --release)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --release requires an argument" >&2; exit 1; }
      release="$2"; shift 2 ;;
    --dars)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --dars requires an argument" >&2; exit 1; }
      dars_dir="$2"; shift 2 ;;
    --window)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --window requires an argument" >&2; exit 1; }
      window="$2"; shift 2 ;;
    --manifest)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --manifest requires an argument" >&2; exit 1; }
      manifest="$2"; shift 2 ;;
    --runtime-tag)
      [[ $# -ge 2 ]] || { echo "devnet-reference: --runtime-tag requires an argument" >&2; exit 1; }
      runtime_tag="$2"; shift 2 ;;
    *)
      echo "devnet-reference: unknown argument: $1" >&2
      exit 1 ;;
  esac
done

case "$network" in
  localnet|localnet-mainnet|devnet) ;;
  *) echo "devnet-reference: --network must be localnet, localnet-mainnet, or devnet, got: $network" >&2; exit 1 ;;
esac

# Every network other than the in-process sandbox is an external participant:
# nothing is started for it, and its endpoint and token must come from the
# environment. Branch on that property, not on the literal "devnet", so adding
# a network does not have to be echoed in four places.
external_participant=true
[[ "$network" == "localnet" ]] && external_participant=false

# Splice image tag for the evidence filename, so one localnet's evidence never
# silently overwrites another release's.
runtime_tag="${runtime_tag:-}"
if [[ "$network" == "localnet-mainnet" && -z "$runtime_tag" && -f "$ROOT/.env.localnet" ]]; then
  runtime_tag="$(sed -n 's/^[[:space:]]*IMAGE_TAG[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$ROOT/.env.localnet" | head -1)"
fi
if [[ "$network" == "localnet-mainnet" && -z "$runtime_tag" ]]; then
  echo "devnet-reference: --network localnet-mainnet needs the Splice image tag; pass --runtime-tag <tag> or create .env.localnet" >&2
  exit 1
fi

# The settle path needs headroom to complete five submissions before the
# deadline; 2s was observed locally against a 20s window, but that margin is
# not what wall-clock latency against a loaded, real participant looks like.
if ! [[ "$window" =~ ^[0-9]+$ ]]; then
  echo "devnet-reference: --window must be a non-negative integer number of seconds, got: $window" >&2
  exit 1
fi
if (( window < 15 )); then
  echo "devnet-reference: --window must be at least 15 seconds (got $window); the settle path" \
    "needs headroom to complete five submissions before the deadline, and wall-clock latency" \
    "against a real participant is not the ~2s seen locally against a static-time sandbox" >&2
  exit 1
fi

# Fail fast, before touching any network, if an external-participant run is
# missing what it needs.
if $external_participant; then
  if [[ -z "${LEDGER_JSON_API:-}" ]]; then
    echo "devnet-reference: --network $network requires LEDGER_JSON_API (and LEDGER_HOST/LEDGER_PORT) in the environment; LEDGER_JSON_API is unset" >&2
    exit 1
  fi
  if [[ -z "${LEDGER_HOST:-}" || -z "${LEDGER_PORT:-}" ]]; then
    echo "devnet-reference: --network $network requires LEDGER_JSON_API, LEDGER_HOST, and LEDGER_PORT in the environment; LEDGER_HOST/LEDGER_PORT is unset" >&2
    exit 1
  fi
  if [[ -n "${LEDGER_CACRT:-}" && ! -f "${LEDGER_CACRT}" ]]; then
    echo "devnet-reference: LEDGER_CACRT is set but not a readable file: ${LEDGER_CACRT}" >&2
    exit 1
  fi
fi

# TLS passthrough for `dpm script`: opt-in only, pure passthrough, never
# inferred from LEDGER_JSON_API's scheme (see header comment).
tls_args=()
if [[ -n "${LEDGER_TLS:-}" ]]; then
  tls_args+=(--tls)
fi
if [[ -n "${LEDGER_CACRT:-}" ]]; then
  tls_args+=(--cacrt "${LEDGER_CACRT}")
fi

# Token files: only ever created on the devnet branch, when LEDGER_TOKEN is
# set. This trap is registered before any sandbox can be started (the
# localnet branch below never reaches this code, and this branch and the
# localnet sandbox-start branch are mutually exclusive on $network), so it
# can never clobber scripts/lib/sandbox.sh's own EXIT trap; see that file's
# header comment. Two files: `dpm script --access-token-file` wants the bare
# token, curl's `-H @file` wants the full header line, and the token itself
# must never sit in argv (visible via `ps`) either way.
token_file=""
header_file=""
token_args=()
auth_header=()
if $external_participant && [[ -n "${LEDGER_TOKEN:-}" ]]; then
  token_file="$(mktemp)"
  header_file="$(mktemp)"
  trap 'rm -f "$token_file" "$header_file"' EXIT
  chmod 600 "$token_file" "$header_file"
  printf '%s' "$LEDGER_TOKEN" > "$token_file"
  printf 'Authorization: Bearer %s' "$LEDGER_TOKEN" > "$header_file"
  token_args=(--access-token-file "$token_file")
  auth_header=(-H "@${header_file}")
fi

mkdir -p "$ROOT/.localnet"
run_dir="$(mktemp -d "$ROOT/.localnet/devnet-reference-$network.XXXXXX")"
staging="$run_dir/dars"
mkdir -p "$staging"

if [[ -n "$release" ]]; then
  echo "==> downloading release $release DARs from tankcdr/conditional-holding-lock"
  gh release download "$release" --repo tankcdr/conditional-holding-lock --pattern '*.dar' --dir "$staging"
  gh release download "$release" --repo tankcdr/conditional-holding-lock --pattern 'conditional-lock-release.json' --dir "$staging"
  if [[ -z "$manifest" ]]; then
    manifest="$staging/conditional-lock-release.json"
  fi
  # The release only carries the three first-party DARs (they are what the
  # manifest tracks); the Splice dependency DARs are not release artifacts
  # and still have to come from a local fetch.
  "$ROOT/scripts/fetch-dars.sh"
  cp "$ROOT/.dars/"*.dar "$staging/"
elif [[ -n "$dars_dir" ]]; then
  echo "==> using DARs from $dars_dir"
  cp "$dars_dir"/*.dar "$staging/"
else
  echo "==> building local first-party packages"
  "$ROOT/scripts/build-dars.sh"
  cp "$ROOT/.dars/"*.dar "$staging/"
  cp "$ROOT/packages/splice-api-token-conditional-lock-v1/.daml/dist/$CL_TOKEN_DAR" "$staging/"
  cp "$ROOT/packages/conditional-lock-utils/.daml/dist/$CL_UTILS_DAR" "$staging/"
  cp "$ROOT/packages/conditional-lock-test-token/.daml/dist/$CL_TEST_TOKEN_DAR" "$staging/"
fi

echo "==> building examples/devnet-escrow"
rm -rf "$EXAMPLE_DIR/dars"
mkdir -p "$EXAMPLE_DIR/dars"
cp "$staging/splice-api-token-metadata-v1-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/splice-api-token-holding-v2-1.0.0.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/$CL_TOKEN_DAR" "$EXAMPLE_DIR/dars/"
cp "$staging/splice-test-token-v2-1.0.1.dar" "$EXAMPLE_DIR/dars/"
cp "$staging/$CL_UTILS_DAR" "$EXAMPLE_DIR/dars/"
cp "$staging/$CL_TEST_TOKEN_DAR" "$EXAMPLE_DIR/dars/"
( cd "$EXAMPLE_DIR" && dpm build )

sandbox_runtime=""
if [[ "$network" == "localnet" ]]; then
  # sandbox.sh registers the kill/wait traps itself, before its startup wait.
  # The sandbox network is testnet (Canton 3.5.17), the pinned runtime we have
  # a checksum for; the evidence's network_runtime stays "localnet".
  CL_SANDBOX_WALL_CLOCK=1 conditional_lock_sandbox_start testnet "$run_dir"
  sandbox_runtime="testnet"
  export LEDGER_JSON_API="http://127.0.0.1:$CL_JSON_PORT"
  export LEDGER_HOST=127.0.0.1
  export LEDGER_PORT="$CL_LEDGER_PORT"
  # The sandbox is unauthenticated. If the caller happens to have a real
  # participant's bearer token exported, do not send it over the loopback
  # connection: a credential that is never transmitted cannot be logged by
  # something on the other end.
  unset LEDGER_TOKEN
fi

echo "==> deploying first-party release DARs"
manifest_args=()
if [[ -n "$manifest" ]]; then manifest_args=(--manifest "$manifest"); fi
"$ROOT/scripts/deploy-dars.sh" ${manifest_args[@]+"${manifest_args[@]}"} \
  "$staging/$CL_TOKEN_DAR" \
  "$staging/$CL_UTILS_DAR" \
  "$staging/$CL_TEST_TOKEN_DAR"

echo "==> deploying Splice dependency DARs and the example DAR"
"$ROOT/scripts/deploy-dars.sh" \
  "$staging/splice-api-token-metadata-v1-1.0.0.dar" \
  "$staging/splice-api-token-holding-v2-1.0.0.dar" \
  "$staging/splice-test-token-v2-1.0.1.dar" \
  "$EXAMPLE_DAR"

echo "$window" > "$run_dir/input.json"

echo "==> running the reference deployment (window=${window}s, wall-clock time)"
# NEVER echo, log, or print LEDGER_TOKEN or the Authorization header.
dpm script --dar "$EXAMPLE_DAR" \
  --script-name EscrowedDvpDevNet:referenceDeployment \
  --ledger-host "$LEDGER_HOST" --ledger-port "$LEDGER_PORT" \
  --input-file "$run_dir/input.json" --output-file "$run_dir/script-output.json" \
  ${token_args[@]+"${token_args[@]}"} \
  ${tls_args[@]+"${tls_args[@]}"}

curl -fsS ${auth_header[@]+"${auth_header[@]}"} "$LEDGER_JSON_API/v2/version" > "$run_dir/ledger-version.json"

# Ledger update IDs: Daml Script returns choice results, not update IDs. The
# JSON Ledger API /v2/updates route was not attempted in this slice (it would
# need probing this participant's schema first, more than the one attempt the
# task allowed for it); record-reference-proof.py ships the contract IDs the
# script itself returned instead and records that honestly.

record_args=(--network "$network" --run-dir "$run_dir" --dar-dir "$staging")
if [[ -n "$runtime_tag" ]]; then record_args+=(--runtime-tag "$runtime_tag"); fi
if [[ -n "$release" ]]; then record_args+=(--release "$release"); fi
if [[ -n "$sandbox_runtime" ]]; then record_args+=(--sandbox-runtime "$sandbox_runtime"); fi

python3 "$ROOT/scripts/record-reference-proof.py" "${record_args[@]}"

evidence_slug="$network"
if [[ -n "$runtime_tag" ]]; then evidence_slug="$network-$runtime_tag"; fi
evidence_path="$ROOT/docs/runbook/${evidence_slug}-reference-evidence.json"
echo "PASS $network; evidence: $evidence_path"
