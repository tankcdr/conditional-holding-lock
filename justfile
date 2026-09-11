# SPDX-License-Identifier: Apache-2.0
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

export PATH := env("HOME") + "/.dpm/bin:" + env("PATH")

_default:
    @just --list

# Build Daml packages, the EVM contract, and the Solana SBF program.
build: check-vectors build-daml build-evm build-solana

# Fetch published Splice DARs and build all first-party Daml packages.
build-daml:
    . ./scripts/lib/java.sh && conditional_lock_java && ./scripts/build-dars.sh

# Build the Solidity reference contract and tests.
build-evm:
    cd contracts/evm && forge build

# Build the Solana program with the pinned SBF toolchain.
build-solana:
    ./scripts/build-solana.sh

# Run all Daml, EVM, and Solana tests.
test:
    ./scripts/test.sh

# Build and run Daml Script tests on the IDE ledger.
test-daml: check-vectors build-daml
    . ./scripts/lib/java.sh && conditional_lock_java && cd packages/conditional-lock-test && dpm test

# Run only the EVM hash-vector tests.
test-evm: check-vectors
    cd contracts/evm && forge test -vv

# Build and run only the Solana SBF hash-vector tests.
test-solana:
    ./scripts/test-solana.sh

# Test local Canton runtimes; defaults to both, or pass mainnet/testnet.
test-compatibility *networks:
    ./scripts/test-compatibility.sh "$@"

# Check generated Daml/Solidity fixtures against the shared JSON.
check-vectors:
    python3 ./scripts/generate-hash-vectors.py --check

# Regenerate Daml/Solidity fixtures after editing the shared JSON.
generate-vectors:
    python3 ./scripts/generate-hash-vectors.py

# Check live Canton network versions and pinned Splice DAR checksums.
check-compatibility:
    python3 ./scripts/check-compatibility.py

# Download and verify the pinned published Splice DARs.
fetch-dars:
    ./scripts/fetch-dars.sh

# Initialize the localnet submodule and fetch published Splice DARs.
setup:
    ./scripts/init-submodules.sh
    ./scripts/fetch-dars.sh

# Run the legacy Splice localnet script with optional arguments.
localnet *args:
    ./scripts/localnet.sh "$@"

# Stop the legacy Splice localnet.
localnet-down:
    ./scripts/localnet.sh --down

# Bootstrap the legacy Splice localnet.
localnet-bootstrap:
    ./scripts/localnet-bootstrap.sh

# Show legacy localnet container status.
localnet-status:
    ./scripts/lib/localnet-compose.sh ps

# Follow legacy localnet logs.
localnet-logs:
    ./scripts/lib/localnet-compose.sh logs -f
