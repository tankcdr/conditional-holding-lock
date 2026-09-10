# Conditional Holding Lock

Apache-2.0 reference implementation of **CIP-cmadison-Conditional-Holding-Lock** for the Canton Network Token Standard.

This repository is a Daml development environment against **Splice main** (SDK **3.5.2**, Daml-LF **2.1**). It follows the same pattern as a Canton localnet overlay: the unpublished token-standard package is built locally and can be uploaded onto a stock Splice localnet before the change exists in the published `splice-app` image.

The CIP itself is CC0-1.0; code here is Apache-2.0.

## Confirmed before posting

| Check | Result |
| --- | --- |
| `DA.Crypto.Text.sha256` / `keccak256` match EVM `sha256(bytes32)` / `keccak256(bytes32)` on shared vectors | **PASS** (`test_hashVectorsMatchEvm` + `forge test`) |
| Receiver authority captured at lock/accept time; `Enact` needs no owner signature | **PASS** (`test_enactWithoutOwnerSignature`) |
| One-step lock when both parties are actors | **PASS** (`test_oneStepLockWhenBothPartiesAct`) |
| Two `Enact` choices on two TestTokenV2 instruments commit atomically | **PASS** (`test_atomicDualEnactDvP`) |

Shared vectors: [`fixtures/hash-vectors.json`](fixtures/hash-vectors.json).

## Layout

```
splice/token-standard/          # sparse Splice main + this CIP
  splice-api-token-conditional-lock-v1/
  splice-token-standard-utils/  # ConditionalLocks.daml (conformance evaluator)
  examples/splice-test-token-v2/
  examples/splice-test-token-conditional-lock-test/
contracts/evm/                  # HashVectors.sol — EVM side of the shared vectors
docs/cip/                       # CIP draft (CC0-1.0)
localnet-overrides/             # how to overlay unpublished DARs onto localnet
scripts/build-dars.sh           # daml build in dep order, symlink *-current.dar
```

Splice pin: `db391b75dd61720460beff6401ca768320e37370` (`canton-network/splice` main).

## Prerequisites

```bash
curl https://get.digitalasset.com/install/install.sh | sh   # DPM
dpm install 3.5.2
# Java 17+ for `dpm test` (the script service). Java 11 is too old for SDK 3.5.2.
export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || echo "$JAVA_HOME")"
```

Foundry is optional and only needed for the EVM vector contract:

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

## Build and test

```bash
./scripts/build-dars.sh
./scripts/test.sh
```

`build-dars.sh` compiles packages in dependency order and symlinks `.daml/dist/<name>-<version>.dar` to `<name>-current.dar`, which is what Splice `daml.yaml` files point at. Outside Splice sbt/Nix, that symlink step is required.

## Localnet overlay

Stock `cn-quickstart` / `splice-app` does not yet contain this package. Overlay it the same way Canton Swap overlays splice confs that the submodule pin has not rolled out: build the DARs here, then upload and vet them on a running localnet. See [`localnet-overrides/README.md`](localnet-overrides/README.md).

## Splice PR shape

The Daml API package is a drop-in under `token-standard/splice-api-token-conditional-lock-v1/`, copied from `splice-api-token-transfer-instruction-v2`. Guard evaluation lives in `splice-token-standard-utils` so every registry uses the same code. That is a CIP conformance property.
