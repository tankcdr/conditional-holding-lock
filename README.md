# Conditional Holding Lock

Apache-2.0 reference code for [CIP-TBD-Conditional-Holding-Lock](docs/cip/CIP-TBD-Conditional-Holding-Lock.md). See [LICENSE](LICENSE) and [NOTICE](NOTICE).

**Status.** The CIP is a draft under review on [Splice PR 7294](https://github.com/canton-network/splice/pull/7294); it has not yet been submitted upstream to `canton-foundation/cips`. The reference implementation's latest release is [v0.2.0](https://github.com/tankcdr/conditional-holding-lock/releases/tag/v0.2.0), interface package ID `ff9cd0184bcd2f3a88b0c8c1c74bcff94e49c7ff00c04e144b33f26f7266811e`.

This repository provides the interface package, a reference policy evaluator a registry can adopt on its own, an adapter over the published TestTokenV2 package, and executable proofs of byte-domain hashing, persistent approver authorization, one-step locking, and atomic two-registry settlement. See the [Conditional Holding Lock validation report](docs/runbook/conditional-lock-validation.md).

## Worked examples

Daml Script tests for all six CIP section 4 worked examples live in [TestWorkedExamples.daml](packages/conditional-lock-test/daml/TestWorkedExamples.daml). Each script checks the example's lifecycle, failed attempts, resulting holdings and locks, and V2 events. The suite contains 94 Daml Scripts: 7 worked-example scripts (the escrowed DvP has a joint and a venue form), 76 mechanics proofs, and 11 policy-limit proofs. See the [validation report's worked-example table](docs/runbook/conditional-lock-validation.md#worked-example-coverage) for the full mapping, including the note that `test_example_dvpBetweenRegistries` exercises only the two-registry `settle` path, not the dispute-window `award` path.

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
just check-pin                # Verify SPLICE_PIN matches its recorded commit
just verify-reproducible      # Two clean builds; compare main package IDs
just release-dry-run <version> # Release checks and manifest; never tags
just publish <version>        # just release, then push the tag and create the GitHub Release
```

Individual builds are available as `build-daml`, `build-evm`, and `build-solana`. The recipes use the existing scripts and tools, which remain directly runnable. Run `just` for setup, fixture generation, and localnet commands.

Prerequisites: DPM with **Daml SDK 3.5.2**, **JDK 21**, Python 3, curl, Foundry (verified with 1.3.6; Solidity 0.8.24), Rust via rustup, and Solana's `cargo-build-sbf` (verified with Agave CLI 3.1.14). The Solana crate selects Rust 1.89.0 locally and the build script pins SBF platform-tools v1.52. All first-party Daml packages target **Daml-LF 2.1** with explicit serializability.

`just test` checks fixture consistency, builds all four Daml packages, runs the Daml Script suite on the IDE ledger, runs both Solidity hash tests, and compiles and tests the Solana hash program in LiteSVM. Foundry and Solana tools are required; neither proof is silently skipped. On macOS the scripts can select Homebrew's `openjdk@21` without changing your global Java installation. On other systems set `JAVA_HOME` to JDK 21.

To run only the Solana proof, use `npm run test:solana` or `./scripts/test-solana.sh`. It executes the compiled SBF program against Agave 3.1.14 runtime dependencies in LiteSVM 0.9.1, checking both hashes against the same six fixtures used by Daml and Solidity. It also checks malformed lengths and accidental UTF-8 hex input. Tests use ephemeral in-memory accounts without an RPC endpoint or wallet file. See the [hash-vector runbook](docs/runbook/hash-vectors.md).

`test-compatibility.sh` downloads checksum-verified official Canton binaries and runs the entire Daml suite through a real Ledger API on each pinned runtime:

| Network reference, checked September 22, 2026 | Splice | Canton | Compiler |
| --------------------------------------------- | ------ | ------ | -------- |
| Mainnet                                       | 0.8.0  | 3.5.16 | 3.5.2    |
| Testnet                                       | 0.8.1  | 3.5.17 | 3.5.2    |

These are isolated local ledgers with controlled time, one participant, and one synchronizer. They use unused loopback ports and stop their own processes on exit. Downloads, logs, package IDs, and JSON results stay in gitignored `.localnet/`. No Docker stack or network funds are needed. The first matrix run downloads about 570 MB.

`just check-compatibility` checks for live network version drift and verifies the upstream DAR checksums; `just test-compatibility testnet` runs just one pinned runtime.

## Dependencies and layout

[SPLICE_PIN](SPLICE_PIN) is a JSON manifest pinning Splice release tag `0.8.1` and recording the tag's commit for moved-tag detection, along with package IDs and SHA-256 checksums. `fetch-dars.sh` verifies its cache and downloads published DARs into gitignored `.dars/`. It replaces incomplete or incorrect downloads only after validation. `SPLICE_DARS_REF` can select another source ref, but the bytes must still match the reviewed pin.

| Path                                             | Purpose                                                                                                                          |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `packages/splice-api-token-conditional-lock-v1/` | The three CIP interfaces and data types; only metadata-v1 and holding-v2 dependencies                                            |
| `packages/conditional-lock-utils/`               | Reference policy evaluator with guard evaluation, terms validation, and outcome resolution; adoptable without TestTokenV2        |
| `packages/conditional-lock-test-token/`          | TestTokenV2 adapter with V1/V2 holding views and V2 events                                                                      |
| `packages/conditional-lock-test/`                | Authority, lifecycle, atomicity, event, and hash proofs                                                                          |
| `fixtures/hash-vectors.json`                     | Single source of reviewed hash vectors; Daml and Solidity generated fixtures are checked for drift; Rust reads the JSON directly |
| `contracts/evm/`                                 | Solidity byte-domain reference and tests; no forge-std checkout needed                                                           |
| `contracts/solana/`                              | Solana SBF hash reference and LiteSVM tests, with a pinned Cargo lockfile and local Rust toolchain                               |
| `fixtures/runtime-versions.json`                 | Network runtime snapshots and official Canton archive checksums                                                                  |
| `CHANGELOG.md`                                   | Release history, build inputs, and package identity per release                                                                  |
| `docs/release-notes/`                            | GitHub Release notes for each tagged version                                                                                     |
| `docs/adoption.md`                               | Consumer adoption guide: dependency sets, verification, registry/application/wallet paths, compatibility                          |
| `docs/adoption-evidence.md`                      | Adoption evidence log and reference-deployment record                                                                             |
| `docs/quickstart/`                               | The minimal consumer project `scripts/quickstart-check.sh` builds and runs end to end                                            |
| `examples/devnet-escrow/`                        | The escrowed-DvP-with-dispute-window script the reference deployment runs                                                         |
| `localnet/`, `localnet-overrides/`               | Splice localnet at the Mainnet release; localnet/ is reference material                                                         |

Splice source and downloaded DARs are never committed here. The interface package is proposed to Splice in [PR 7294](https://github.com/canton-network/splice/pull/7294).

## Releases

Releases are cut from a `v<version>` git tag, and every first-party Daml package carries that version in `daml.yaml` and its DAR name (`v0.1.0` predates this and ships `*-1.0.0.dar`). The three consumer DARs are attached to the GitHub Release, along with the generated `conditional-lock-release.json` manifest and `fixtures/hash-vectors.json`. Release mechanics live in two files and nowhere else: [CHANGELOG.md](CHANGELOG.md) for the per-release history, the versioning rule, and package identity, and `docs/release-notes/<tag>.md` for the release body. `just release-dry-run <version>` runs every release check except the clean-worktree and tag-exists guards, and never tags.

## Adopting the DARs

[docs/adoption.md](docs/adoption.md) is the document for someone outside this repository: it takes a registry, an application, or a wallet from an empty project to a working conditional lock against the released DARs, without waiting for Splice to merge the interface. It covers which of the four packages to depend on, how to fetch and verify them, the `daml.yaml` each audience writes, the wallet's OpenAPI surface, and what re-pinning costs while this is `0.x`. `just quickstart` runs its end-to-end example on an isolated sandbox.

The reference deployment runs the CIP's worked example of escrowed delivery-versus-payment via `just devnet-reference`, which executes it under wall-clock time, required for time-bounded guards, defaulting to an isolated sandbox but also targeting `--network localnet-mainnet` (the Docker Splice localnet at the Mainnet release; see [docs/runbook/localnet.md](docs/runbook/localnet.md)) and live network with `--network devnet`, `LEDGER_JSON_API`, `LEDGER_HOST`, `LEDGER_PORT`, and optionally `LEDGER_TOKEN`. Evidence is written to `docs/runbook/<network>-reference-evidence.json`; the adoption evidence log at [docs/adoption-evidence.md](docs/adoption-evidence.md) records each run. Use `just devnet-status` to compare the live DevNet Splice version against SPLICE_PIN (informational only). No Canton Coin or network funds are required.

## Reference scope

The adapter consumes and creates **actual published `Splice.Testing.Tokens.TestTokenV2.Holding.Token` contracts**. Locked funds have a distinct backing template, visible through both holding interfaces. Acceptance adds approver account parties as ledger signatories; subsequent enactment can use that stored authority. Both the account owner and provider, when present, must authorize account movements. Factories are registry-issued, single-use contracts with distinct lock IDs.

This proves the Daml mechanics. The [integration test](docs/runbook/localnet.md) settles a real Canton Coin (Amulet) payment leg atomically against a locked TestTokenV2 delivery leg, demonstrating the conditional lock as a building block in multi-registry DvP. The lock is not a Canton Coin lock, the locked asset remains registry-issued TestTokenV2, but it settles against one as a counter-asset. This is not a token-standard conformance certification, a registry HTTP server, or a public-network deployment. TestTokenV2 is a test issuer; production registry account policies, preapprovals, external signing, and Canton Coin submission delays still need their planned implementations.

The Solana proof establishes matching SHA-256 and Keccak-256 byte semantics in a local VM. A Solana token escrow, cross-chain swap lifecycle, and public-cluster compatibility validation remain separate work.

## Splice localnet at the Mainnet release

```bash
./scripts/localnet-sync.sh [<tag>] [--check]  # Materialize/update the Splice tree
./scripts/localnet.sh                         # Up, wait for readiness, bootstrap
./scripts/localnet-prove.sh                   # Escrowed-DvP proof, writes evidence
pnpm test:integration                         # DvP-between-registries integration test
./scripts/localnet.sh --down                  # Stop, keep volumes
```

The 94-script Daml test suite runs against this localnet too, 77 of 94 passing (the other 17 need a controllable clock this participant does not have). See [docs/runbook/localnet.md](docs/runbook/localnet.md) for credentials, ports, party-id hints, the 16-failure analysis, the `localnet/` submodule's history, and the integration test's known flake. The vendored Splice tree's provenance is in [localnet-overrides/README.md](localnet-overrides/README.md).
