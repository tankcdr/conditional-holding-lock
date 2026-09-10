# Conditional Holding Lock

Apache-2.0 Daml development environment for **CIP-cmadison-Conditional-Holding-Lock**, shaped like [canton-swap-monorepo](https://github.com/interstice) localnet: a `cn-quickstart` submodule, compose overlay, and unpublished confs/DARs mounted or uploaded on top of stock Splice.

The CIP itself is CC0-1.0; code here is Apache-2.0.

## What this repo is

Canton Swap’s `localnet/` submodule is `digital-asset/cn-quickstart`. Unpublished Splice confs live in `localnet-overrides/` and are bind-mounted into the splice container because the quickstart pin is older than the splice-app image. First-party DARs are built on the host and uploaded onto the running participant.

This repo does the same thing, without the swap product (no orchestrator, Keycloak, Supabase, or Solana):

| Path | Role |
| --- | --- |
| `localnet/` | git submodule → `digital-asset/cn-quickstart` (how you **run** Canton) |
| `localnet-overrides/splice-0.6.7/` | splice confs the quickstart pin does not ship |
| `docker-compose.localnet.yml` | canton + splice-app + postgres + wallet/scan UIs |
| `scripts/localnet.sh` | up, wait, upload CIP DARs |
| `splice/` | git submodule → `tankcdr/splice` `@ cip-conditional-holding-lock` (how you **PR** the CIP) |
| `contracts/evm/` | shared hash vectors |

## Confirmed on SDK 3.5.2

| Check | Result |
| --- | --- |
| `DA.Crypto.Text.sha256` / `keccak256` match EVM `sha256(bytes32)` / `keccak256(bytes32)` | PASS |
| Receiver authority captured at lock time; `Enact` needs no owner signature | PASS |
| One-step lock when both parties are actors | PASS |
| Two `Enact`s on two TestTokenV2 instruments commit atomically | PASS |

## Clone

```bash
git clone https://github.com/tankcdr/conditional-holding-lock.git
cd conditional-holding-lock
./scripts/init-submodules.sh
```

`init-submodules.sh` pulls `localnet` (depth 1) and a blobless sparse checkout of `splice` (`token-standard` only). Do not `--recurse-submodules` on splice — the full tree is huge.

## Prerequisites

```bash
curl https://get.digitalasset.com/install/install.sh | sh   # DPM
dpm install 3.5.2
# Java 17+ for `dpm test`
docker compose version
```

## Daml build and tests (no ledger)

```bash
./scripts/build-dars.sh
./scripts/test.sh
```

## Localnet (the canton-swap path)

```bash
cp .env.localnet.example .env.localnet
./scripts/localnet.sh            # compose up, wait, upload CIP DARs
./scripts/localnet.sh --down
./scripts/localnet.sh --clean    # also drop volumes
```

| Service | Port |
| --- | --- |
| App-provider JSON API | 3975 |
| App-user wallet UI | 2000 |
| Scan UI | 4000 |

Unpublished splice-app confs are mounted from `localnet-overrides/splice-0.6.7/` — same reason as canton-swap: quickstart’s confs still use pre-0.6.7 synchronizer-node keys. Unpublished CIP DARs are uploaded by `scripts/localnet-bootstrap.sh` via `POST /v2/packages`.

## Splice PR

Daml edits go in the `splice` submodule so the PR onto `canton-network/splice` is already a branch: https://github.com/tankcdr/splice/tree/cip-conditional-holding-lock
