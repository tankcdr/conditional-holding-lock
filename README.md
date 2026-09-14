# Conditional Holding Lock

Apache-2.0 reference code for [CIP-TBD-Conditional-Holding-Lock](docs/cip/CIP-TBD-Conditional-Holding-Lock.md).

Step 1 provides the interface package, an adapter over the published TestTokenV2 package, and executable proofs of byte-domain hashing, persistent receiver authorization, one-step locking, and atomic two-registry settlement. See the [compatibility and proof report](docs/runbook/step-1.md).

## Worked examples

The Development Fund proposal's M1 promise of Daml Script tests for all six CIP section 4 worked examples maps to the scripts in [TestWorkedExamples.daml](packages/conditional-lock-test/daml/TestWorkedExamples.daml). Each script checks the example's lifecycle, failed attempts, resulting holdings and locks, and V2 events. The suite contains 29 Daml Scripts, including the 23 mechanics proofs.

| CIP section 4 example | Named script | Mechanics proofs it relies on |
| --- | --- | --- |
| HTLC leg | `test_example_htlcLeg` | receiver authority, expiry boundary, Keccak vs SHA-256, hash vectors |
| Executor-free DvP | `test_example_executorFreeDvp` | atomic two-registry DvP, rollback, threshold spoofing |
| Arbiter escrow | `test_example_arbiterEscrow` | distribute bounds, multiple receivers, partial fallback |
| Vesting | `test_example_vesting` | partial release conservation, spent-rule resurrection, nested guard boundaries |
| Collateral | `test_example_collateral` | unlock without acceptance, amend top-up, amend cannot change asset |
| Conditional payment | `test_example_conditionalPayment` | nested guards (inclusive After, exclusive Before), enactor and threshold |

## Build and prove

Use [Just](https://github.com/casey/just) as the command runner (verified with 1.58.0; `brew install just` on macOS):

```bash
just                          # List available commands
just build                    # Build Daml, EVM, and Solana
just test                     # Run all three test suites
just test-daml                # Daml Script tests only
just test-evm                 # EVM hash vectors only
just test-solana              # Solana SBF hash vectors only
just test-compatibility       # Local ledgers for both pinned Canton runtimes
just test-compatibility testnet
just check-vectors
just check-compatibility      # Check live Canton version drift
```

Recipe names use hyphens, such as `test-evm`; Just's [recipe-name grammar](https://github.com/casey/just/blob/master/GRAMMAR.md) does not allow `test:evm`. Individual builds are available as `build-daml`, `build-evm`, and `build-solana`. The recipes use the existing scripts and tools, which remain directly runnable. Run `just` for setup, fixture generation, and legacy localnet commands.

Prerequisites: DPM with **Daml SDK 3.5.2**, **JDK 21**, Python 3, curl, Foundry (verified with 1.3.6; Solidity 0.8.24), Rust via rustup, and Solana's `cargo-build-sbf` (verified with Agave CLI 3.1.14). The Solana crate selects Rust 1.89.0 locally and the build script pins SBF platform-tools v1.52. All first-party Daml packages target **Daml-LF 2.1** with explicit serializability.

```bash
dpm install 3.5.2
./scripts/fetch-dars.sh
./scripts/test.sh
./scripts/test-compatibility.sh
```

`test.sh` checks fixture consistency, builds all three Daml packages, runs the Daml Script suite on the IDE ledger, runs both Solidity hash tests, and compiles and tests the Solana hash program in LiteSVM. Foundry and Solana tools are required; neither proof is silently skipped. On macOS the scripts can select Homebrew's `openjdk@21` without changing your global Java installation. On other systems set `JAVA_HOME` to JDK 21.

To run only the Solana proof, use `npm run test:solana` or `./scripts/test-solana.sh`. It executes the compiled SBF program against Agave 3.1.14 runtime dependencies in LiteSVM 0.9.1, checking both hashes against the same six fixtures used by Daml and Solidity. It also checks malformed lengths and accidental UTF-8 hex input. Tests use ephemeral in-memory accounts without an RPC endpoint or wallet file. See the [hash-vector runbook](docs/runbook/hash-vectors.md).

`test-compatibility.sh` downloads checksum-verified official Canton binaries and runs the entire Daml suite through a real Ledger API on each pinned runtime:

| Network reference, checked September 11, 2026 | Splice | Canton | Compiler |
| --------------------------------------------- | ------ | ------ | -------- |
| Mainnet                                       | 0.7.4  | 3.5.14 | 3.5.2    |
| Testnet                                       | 0.7.5  | 3.5.15 | 3.5.2    |

These are isolated local ledgers with controlled time, one participant, and one synchronizer. They use unused loopback ports and stop their own processes on exit. Downloads, logs, package IDs, and JSON results stay in gitignored `.localnet/`. No Docker stack or network funds are needed. The first matrix run downloads about 570 MB.

To check for live network version drift and verify the upstream DAR checksums:

```bash
python3 scripts/check-compatibility.py
# Run just one pinned runtime:
./scripts/test-compatibility.sh testnet
```

## Dependencies and layout

[SPLICE_PIN](SPLICE_PIN) is a JSON manifest pinning a specific Splice `main` commit, package IDs, and SHA-256 checksums. `fetch-dars.sh` verifies its cache and downloads published DARs into gitignored `.dars/`. It replaces incomplete or incorrect downloads only after validation. `SPLICE_DARS_REF` can select another source ref, but the bytes must still match the reviewed pin.

| Path                                             | Purpose                                                                                                                          |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `packages/splice-api-token-conditional-lock-v1/` | The three CIP interfaces and data types; only metadata-v1 and holding-v2 dependencies                                            |
| `packages/conditional-lock-test-token/`          | First-party reference policy and TestTokenV2 adapter, including V1/V2 holding views and V2 events                                |
| `packages/conditional-lock-test/`                | Authority, lifecycle, atomicity, event, and hash proofs                                                                          |
| `fixtures/hash-vectors.json`                     | Single source of reviewed hash vectors; Daml and Solidity generated fixtures are checked for drift; Rust reads the JSON directly |
| `contracts/evm/`                                 | Solidity byte-domain reference and tests; no forge-std checkout needed                                                           |
| `contracts/solana/`                              | Solana SBF hash reference and LiteSVM tests, with a pinned Cargo lockfile and local Rust toolchain                               |
| `fixtures/runtime-versions.json`                 | Network runtime snapshots and official Canton archive checksums                                                                  |
| `localnet/`, `localnet-overrides/`               | Legacy cn-quickstart Splice layout, separate from the proof matrix                                                               |

Splice source and downloaded DARs are never committed here. A future Splice implementation PR belongs on a Splice fork.

## Reference scope

The adapter consumes and creates **actual published `Splice.Testing.Tokens.TestTokenV2.Holding.Token` contracts**. Locked funds have a distinct backing template, visible through both holding interfaces. Acceptance adds receiver account parties as ledger signatories; subsequent enactment can use that stored authority. Both owner and provider, when present, must authorize account movements. Factories are registry-issued, single-use contracts with distinct lock IDs.

This proves the Daml mechanics. It is not a Canton Coin integration, a full token-standard conformance certification, a registry HTTP server, or a public-network deployment. TestTokenV2 is a test issuer; production registry account policies, preapprovals, external signing, and Canton Coin submission delays still need their planned implementations.

The Solana proof establishes matching SHA-256 and Keccak-256 byte semantics in a local VM. A Solana token escrow, cross-chain swap lifecycle, and public-cluster compatibility validation remain separate work.

## Legacy Splice localnet

The compose overlay remains pinned to Splice 0.6.7 / Canton image 0.6.8, whose participant reports Canton 3.5.4. It is **not** the current network compatibility target. The existing running stack on the development machine belongs to another checkout and was left running.

For Step 1 use `test-compatibility.sh`. Use the legacy `localnet.sh` only when deliberately working on that topology; its fixed container names and ports are shared with the canton-swap layout. It requires `./scripts/init-submodules.sh` and `.env.localnet` copied from `.env.localnet.example`.
