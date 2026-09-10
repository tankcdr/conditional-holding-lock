# Conditional Holding Lock

Apache-2.0 Daml development environment for **CIP-cmadison-Conditional-Holding-Lock**, shaped like canton-swap-monorepo localnet: a `cn-quickstart` submodule, compose overlay, and unpublished confs/DARs mounted or uploaded on top of stock Splice.

**This repository does not contain Splice source.** The CIP Daml lives on a fork: https://github.com/tankcdr/splice/tree/cip-conditional-holding-lock

The CIP itself is CC0-1.0; code here is Apache-2.0.

## What is in this repo

| Path | Role |
| --- | --- |
| `localnet/` | git submodule → `digital-asset/cn-quickstart` |
| `localnet-overrides/splice-0.6.7/` | splice confs the quickstart pin does not ship |
| `docker-compose.localnet.yml` | canton + splice-app + postgres + wallet/scan UIs |
| `scripts/localnet.sh` | up, wait, upload CIP DARs |
| `contracts/evm/` | shared hash vectors |
| `docs/cip/` | CIP draft |

Clone Splice separately (gitignored as `./splice`):

```bash
./scripts/clone-splice.sh
# or: export SPLICE_DIR=/path/to/tankcdr/splice
```

## Confirmed on SDK 3.5.2

| Check | Result |
| --- | --- |
| `DA.Crypto.Text.sha256` / `keccak256` match EVM `sha256(bytes32)` / `keccak256(bytes32)` | PASS |
| Receiver authority captured at lock time; `Enact` needs no owner signature | PASS |
| One-step lock when both parties are actors | PASS |
| Two `Enact`s on two TestTokenV2 instruments commit atomically | PASS |

## Clone

```bash
git clone --recurse-submodules https://github.com/tankcdr/conditional-holding-lock.git
cd conditional-holding-lock
./scripts/init-submodules.sh    # cn-quickstart only
./scripts/clone-splice.sh       # CIP fork, not committed here
```

## Prerequisites

```bash
curl https://get.digitalasset.com/install/install.sh | sh
dpm install 3.5.2
# Java 17+ for `dpm test`
docker compose version
```

## Daml build and tests

```bash
./scripts/build-dars.sh
./scripts/test.sh
```

## Localnet

```bash
cp .env.localnet.example .env.localnet
./scripts/localnet.sh
```

| Service | Port |
| --- | --- |
| App-provider JSON API | 3975 |
| App-user wallet UI | 2000 |
| Scan UI | 4000 |
