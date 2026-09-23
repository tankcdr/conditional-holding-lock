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

# Check SPLICE_PIN's tag identity against the upstream repository.
check-pin:
    python3 ./scripts/check-pin.py

# Rebuild all first-party packages twice and confirm package IDs reproduce.
verify-reproducible:
    ./scripts/verify-reproducible.sh

# Run the consumer quickstart end to end on an isolated sandbox.
quickstart *dar_dir:
    ./scripts/quickstart-check.sh "$@"

# Upload DARs to a participant. Set LEDGER_JSON_API and, if the participant requires auth, LEDGER_TOKEN.
devnet-deploy *args:
    ./scripts/deploy-dars.sh "$@"

# Run the escrowed-DvP reference deployment and record its evidence.
devnet-reference *args:
    ./scripts/devnet-reference.sh "$@"

# Compare the live DevNet Splice version against the pinned release in SPLICE_PIN.
devnet-status:
    ./scripts/devnet-status.sh

# Cut a release: verify everything, write the manifest, and tag the commit.
release version:
    if git rev-parse -q --verify "refs/tags/v{{version}}" >/dev/null; then echo "Tag v{{version}} already exists" >&2; exit 1; fi
    if [ -n "$(git status --porcelain)" ]; then echo "Worktree is dirty" >&2; exit 1; fi
    python3 ./scripts/make-release-manifest.py "{{version}}" --check-changelog-only
    just check-pin
    just check-compatibility
    just verify-reproducible
    ./scripts/test.sh
    ./scripts/test-compatibility.sh
    ./scripts/quickstart-check.sh
    python3 ./scripts/make-release-manifest.py "{{version}}"
    git tag -a "v{{version}}" -m "conditional-holding-lock v{{version}}"

# Cut and publish a release: `just release`, then push the tag and create the GitHub Release with its assets.
publish version:
    just release {{version}}
    ./scripts/publish-release.sh {{version}}

# Check what `just publish` would push and attach, without pushing or creating anything.
publish-dry-run version:
    ./scripts/publish-release.sh {{version}} --dry-run

# Dry-run the release checks and manifest without tagging; never tags.
release-dry-run version: check-pin check-compatibility verify-reproducible
    ./scripts/test.sh
    ./scripts/test-compatibility.sh
    ./scripts/quickstart-check.sh
    python3 ./scripts/make-release-manifest.py "{{version}}" --allow-dirty

# Download and verify the pinned published Splice DARs.
fetch-dars:
    ./scripts/fetch-dars.sh

# Initialize the localnet submodule and fetch published Splice DARs.
setup:
    ./scripts/init-submodules.sh
    ./scripts/fetch-dars.sh

# Start the Splice localnet at the Mainnet release, wait, and upload the DARs.
localnet *args:
    ./scripts/localnet.sh "$@"

# Stop the localnet, keeping its volumes.
localnet-down:
    ./scripts/localnet.sh --down

# Stop the localnet and delete its volumes (a fresh ledger next start).
localnet-clean:
    ./scripts/localnet.sh --clean

# Build the first-party DARs and upload them onto a running localnet.
localnet-bootstrap:
    ./scripts/localnet-bootstrap.sh

# Re-sync the vendored Splice localnet tree to the release live on Mainnet.
localnet-sync *args:
    ./scripts/localnet-sync.sh "$@"

# Run the escrowed-DvP reference deployment on the running localnet.
localnet-prove *args:
    ./scripts/localnet-prove.sh "$@"

# Show localnet container status.
localnet-status:
    ./scripts/lib/localnet-compose.sh ps

# Follow localnet logs.
localnet-logs:
    ./scripts/lib/localnet-compose.sh logs -f

# Run the DvP integration test against the running Mainnet-configuration localnet.
test-integration:
    pnpm test:integration

# Record the last DvP integration run's evidence. Regenerated, never hand-edited.
test-integration-evidence:
    tag="$(grep -E '^IMAGE_TAG=' .env.localnet 2>/dev/null | cut -d= -f2 || true)"; \
    if [ -z "$tag" ]; then \
      echo "test-integration-evidence: no IMAGE_TAG in .env.localnet; it predates the Splice compose stack. Delete it and rerun ./scripts/localnet.sh" >&2; \
      exit 1; \
    fi; \
    python3 ./scripts/record-reference-proof.py --kind dvp --network localnet-mainnet \
      --runtime-tag "$tag" \
      --run-dir integration/.run; \
    ./scripts/tests/dvp-evidence-tamper.sh "$tag"
