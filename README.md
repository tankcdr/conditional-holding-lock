# Conditional Holding Lock

Apache-2.0 reference code for [CIP-TBD-Conditional-Holding-Lock](docs/cip/CIP-TBD-Conditional-Holding-Lock.md).

This repository provides the interface package, a reference policy evaluator a registry can adopt on its own, an adapter over the published TestTokenV2 package, and executable proofs of byte-domain hashing, persistent approver authorization, one-step locking, and atomic two-registry settlement. See the [Conditional Holding Lock validation report](docs/runbook/conditional-lock-validation.md).

## Worked examples

Daml Script tests for all six CIP section 4 worked examples live in [TestWorkedExamples.daml](packages/conditional-lock-test/daml/TestWorkedExamples.daml). Each script checks the example's lifecycle, failed attempts, resulting holdings and locks, and V2 events. The suite contains 70 Daml Scripts: 6 worked-example scripts, 54 mechanics proofs, and 10 policy-limit proofs.

| CIP section 4 example | Named script | Mechanics proofs it relies on |
| --- | --- | --- |
| HTLC leg | `test_example_htlcLeg` | approver authority, expiry boundary, Keccak vs SHA-256, hash vectors |
| Escrowed DvP with a dispute window | `test_example_dvpBetweenRegistries` | atomic two-registry DvP, rollback, threshold spoofing |
| Arbiter escrow | `test_example_arbiterEscrow` | release bounds, multiple receivers, expiry refund |
| Vesting | `test_example_vesting` | partial release conservation, spent-rule resurrection, guard boundaries (inclusive After, exclusive Before) |
| Collateral | `test_example_collateral` | unlock without acceptance, amend top-up, amend cannot change asset |
| Conditional payment | `test_example_conditionalPayment` | alternatives and guard boundaries (inclusive After, exclusive Before), enactor and threshold |

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
just release-dry-run 0.1.0    # Release checks and manifest; never tags
```

Recipe names use hyphens, such as `test-evm`; Just's [recipe-name grammar](https://github.com/casey/just/blob/master/GRAMMAR.md) does not allow `test:evm`. Individual builds are available as `build-daml`, `build-evm`, and `build-solana`. The recipes use the existing scripts and tools, which remain directly runnable. Run `just` for setup, fixture generation, and localnet commands.

Prerequisites: DPM with **Daml SDK 3.5.2**, **JDK 21**, Python 3, curl, Foundry (verified with 1.3.6; Solidity 0.8.24), Rust via rustup, and Solana's `cargo-build-sbf` (verified with Agave CLI 3.1.14). The Solana crate selects Rust 1.89.0 locally and the build script pins SBF platform-tools v1.52. All first-party Daml packages target **Daml-LF 2.1** with explicit serializability.

```bash
dpm install 3.5.2
./scripts/fetch-dars.sh
./scripts/test.sh
./scripts/test-compatibility.sh
```

`test.sh` checks fixture consistency, builds all four Daml packages, runs the Daml Script suite on the IDE ledger, runs both Solidity hash tests, and compiles and tests the Solana hash program in LiteSVM. Foundry and Solana tools are required; neither proof is silently skipped. On macOS the scripts can select Homebrew's `openjdk@21` without changing your global Java installation. On other systems set `JAVA_HOME` to JDK 21.

To run only the Solana proof, use `npm run test:solana` or `./scripts/test-solana.sh`. It executes the compiled SBF program against Agave 3.1.14 runtime dependencies in LiteSVM 0.9.1, checking both hashes against the same six fixtures used by Daml and Solidity. It also checks malformed lengths and accidental UTF-8 hex input. Tests use ephemeral in-memory accounts without an RPC endpoint or wallet file. See the [hash-vector runbook](docs/runbook/hash-vectors.md).

`test-compatibility.sh` downloads checksum-verified official Canton binaries and runs the entire Daml suite through a real Ledger API on each pinned runtime:

| Network reference, checked September 22, 2026 | Splice | Canton | Compiler |
| --------------------------------------------- | ------ | ------ | -------- |
| Mainnet                                       | 0.8.0  | 3.5.16 | 3.5.2    |
| Testnet                                       | 0.8.1  | 3.5.17 | 3.5.2    |

These are isolated local ledgers with controlled time, one participant, and one synchronizer. They use unused loopback ports and stop their own processes on exit. Downloads, logs, package IDs, and JSON results stay in gitignored `.localnet/`. No Docker stack or network funds are needed. The first matrix run downloads about 570 MB.

To check for live network version drift and verify the upstream DAR checksums:

```bash
python3 scripts/check-compatibility.py
# Run just one pinned runtime:
./scripts/test-compatibility.sh testnet
```

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

Splice source and downloaded DARs are never committed here. A future Splice implementation PR belongs on a Splice fork.

## Releases

Releases are cut from a `v<version>` git tag, starting at `v0.1.0`; the Daml packages keep `version: 1.0.0` in `daml.yaml`. The three consumer DARs are attached to the GitHub Release, and the generated `conditional-lock-release.json` manifest is attached alongside them. Release mechanics live in two files and nowhere else: [CHANGELOG.md](CHANGELOG.md) for the per-release history, the versioning rule, and package identity, and [docs/release-notes/v0.1.0.md](docs/release-notes/v0.1.0.md) for the release body. `just release-dry-run <version>` runs every release check except the clean-worktree and tag-exists guards, and never tags.

## Adopting the DARs

[docs/adoption.md](docs/adoption.md) is the document for someone outside this repository: it takes a registry, an application, or a wallet from an empty project to a working conditional lock against the released DARs, without waiting for Splice to merge the interface. It covers which of the four packages to depend on, how to fetch and verify them, the `daml.yaml` each audience writes, the wallet's OpenAPI surface, and what re-pinning costs while this is `0.x`. `just quickstart` runs its end-to-end example on an isolated sandbox.

The reference deployment runs the CIP's worked example of escrowed delivery-versus-payment via `just devnet-reference`, which executes it under wall-clock time—required for time-bounded guards—defaulting to an isolated sandbox but targeting live network with `--network devnet`, `LEDGER_JSON_API`, `LEDGER_HOST`, `LEDGER_PORT`, and optionally `LEDGER_TOKEN`. Evidence is recorded in [docs/adoption-evidence.md](docs/adoption-evidence.md). Use `just devnet-status` to compare the live DevNet Splice version against SPLICE_PIN (informational only). No Canton Coin or network funds are required.

## Reference scope

The adapter consumes and creates **actual published `Splice.Testing.Tokens.TestTokenV2.Holding.Token` contracts**. Locked funds have a distinct backing template, visible through both holding interfaces. Acceptance adds approver account parties as ledger signatories; subsequent enactment can use that stored authority. Both the account owner and provider, when present, must authorize account movements. Factories are registry-issued, single-use contracts with distinct lock IDs.

This proves the Daml mechanics. It is not a Canton Coin integration, a full token-standard conformance certification, a registry HTTP server, or a public-network deployment. TestTokenV2 is a test issuer; production registry account policies, preapprovals, external signing, and Canton Coin submission delays still need their planned implementations.

The Solana proof establishes matching SHA-256 and Keccak-256 byte semantics in a local VM. A Solana token escrow, cross-chain swap lifecycle, and public-cluster compatibility validation remain separate work.

## Splice localnet at the Mainnet release

The localnet stack is Splice's own compose files, vendored verbatim under `localnet-overrides/splice-0.8.0/` (Splice commit `9330dba9e31b8893bec09ece2f5dbb496fcf17b5`, tag `0.8.0`), which is what Canton Mainnet runs today. The driver (`scripts/lib/localnet-compose.sh`, project name `conditional-lock-localnet`) runs Splice's compose and resource-constraints files with the `sv`, `app-provider`, and `app-user` profiles in their `auth-on` variants, using Splice's `compose.env` and `env/common.env` as env files. The only first-party file is `localnet-overrides/conditional-lock.compose.yaml`, a compose layer that pins the app-provider participant's admin token.

```bash
./scripts/localnet-sync.sh [<tag>] [--check]   # Materialize/update the Splice tree
./scripts/localnet.sh [--down] [--clean] [--no-bootstrap]  # Up, wait, bootstrap
./scripts/localnet-bootstrap.sh                # Re-upload DARs without restarting
./scripts/localnet-prove.sh                    # Escrowed-DvP proof (output to docs/runbook/localnet-mainnet-0.8.0-reference-evidence.json)
```

Each script also has a `just` recipe and an `npm run localnet:…` script. Note that `just check-compatibility` fails when `.env.localnet.example`'s `IMAGE_TAG` is not the Splice version live on Mainnet, so `just release` fails until you re-sync the localnet with `./scripts/localnet-sync.sh`.

Two credentials are in play, both unsafe and local-only by design, both from `scripts/lib/localnet_token.py`. The default is an HS256 JWT for user `ledger-api-user`, audience `https://canton.network.global`, secret `unsafe`; the helper reads the user from `env/app-provider-auth-on.env` and the secret from `conf/canton/app-provider/app-auth.conf` in the vendored tree. DAR upload uses it. With `--admin`, the tool returns the participant admin token that `localnet-overrides/conditional-lock.compose.yaml` pins for the app-provider participant, carrying claims `ClaimPublic`, `ClaimAdmin`, and `ClaimActAsAnyParty`. Anything that runs Daml Script needs the admin token: Daml Script allocates its own parties at runtime, Canton grants act-as rights only to the user named in the `AllocateParty` request's `userId` field (which Daml Script does not set; `dpm script --user-id` changes only the submitting user), and Canton 3.5.16 has no `CanActAsAnyParty` right to pre-grant. Splice's vendored tree already enables the admin claim; our compose layer adds the act-as-any-party claim and pins the token value. Authentication stays on; this is a stronger named credential, not a bypass. Never reuse either credential against a real network.

Daml Script derives deterministic party-id hints (e.g., `alice-d4d95138`), so a second proof run against the same persistent participant fails at `allocateParty` with "Party already exists". The preflight detects this and instructs you to run `./scripts/localnet.sh --clean && ./scripts/localnet.sh` first.

The 70-script Daml test suite does not run on this localnet: all 70 scripts allocate the same party names, so after the first script the rest collide; additionally, the participant reports `staticTime.supported: false` and some scripts need static time to pass a deadline. Use `dpm test` or `./scripts/test-compatibility.sh` for the suite; the localnet proves the lock against the live Mainnet configuration.

Ports follow Splice's pattern (suffixes 901 gRPC Ledger, 902 admin, 975 JSON Ledger, 903 validator admin): app-provider is 3975 JSON / 3901 gRPC / 3903 validator; app-user is 2975 / 2901 / 2903; SV is 4975 / 4901 / 4903. UIs: app-user wallet `http://wallet.localhost:2000`, app-provider wallet `http://wallet.localhost:3000`, SV `http://sv.localhost:4000`, scan `http://scan.localhost:4000`. Postgres is on host port 5433 (`DB_PORT` in `.env.localnet.example`), not Splice's 5432, because another project's stack commonly holds 5432.

The `localnet/` submodule (`digital-asset/cn-quickstart`, 0BSD, currently pinned to `33eddeb992d4a16de18685585617a4c54e91ceac`) is no longer used by the stack itself; it provides reference material: the quickstart application, devnet and keycloak modules, and `quickstart/sync-network.sh` as prior art for reading a version out of a network info URL (`quickstart/sync-network.sh` reads `.synchronizer.active.version`; `scripts/localnet-sync.sh` and `scripts/check-compatibility.py` read `.sv.version` the same way).
