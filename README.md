# Conditional Holding Lock

Apache-2.0 Daml development environment for **CIP-cmadison-Conditional-Holding-Lock**. Localnet layout follows canton-swap: `cn-quickstart` submodule, compose overlay, unpublished confs/DARs on top of stock Splice.

This repo does **not** contain Splice source. It downloads the published token-standard **DARs** into gitignored `.dars/` and compiles first-party packages against them.

CIP Daml PR (optional, separate): https://github.com/tankcdr/splice/tree/cip-conditional-holding-lock

## Layout

| Path | Role |
| --- | --- |
| `packages/splice-api-token-conditional-lock-v1/` | CIP interface package |
| `packages/conditional-lock-test/` | hash-vector Daml Script |
| `.dars/` | fetched Splice interface DARs (gitignored) |
| `localnet/` | submodule → `digital-asset/cn-quickstart` |
| `localnet-overrides/` | splice-app 0.6.7 confs the quickstart pin lacks |
| `contracts/evm/` | shared hash vectors |

## Setup

```bash
git clone --recurse-submodules https://github.com/tankcdr/conditional-holding-lock.git
cd conditional-holding-lock
./scripts/init-submodules.sh
./scripts/fetch-dars.sh
```

`fetch-dars.sh` pulls `splice-api-token-metadata-v1` and `splice-api-token-holding-v2` from `canton-network/splice` `daml/dars/` on `main`.

## Build and test

```bash
./scripts/build-dars.sh
./scripts/test.sh
```

## Localnet

```bash
cp .env.localnet.example .env.localnet
./scripts/localnet.sh
```
