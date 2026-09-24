# Conditional Holding Lock: validation and runtime compatibility

Evaluation date: **September 22, 2026**. This report covers the reference interface and registry adapter: worked-example lifecycles, approver authority, atomic settlement, event reporting, byte-domain hashing, and compatibility with the pinned Canton runtimes.

This report answers "does the reference implementation work, and against what". It is not the adoption path: if you want to depend on these packages from your own project, read [docs/adoption.md](../adoption.md) instead.

## Environment and compatibility

| Component | Observed configuration | Assessment |
| --- | --- | --- |
| Compiler | DPM 1.0.21; SDK 3.5.2 | Matches Splice release tag `0.8.1` and both network references |
| First-party language target | LF 2.1; explicit serializability | Matches the V2 packages; no development LF target |
| Java | Project tests select installed JDK 21 | Tests do not depend on an unsupported global Java or stale `JAVA_HOME` |
| Foundry | 1.3.6, Solidity 0.8.24 | Both byte-domain hash algorithms tested |
| Solana | Agave CLI/runtime dependencies 3.1.14, platform-tools v1.52, Rust 1.89.0, LiteSVM 0.9.1 | Compiled SBF program matches both hashes on the shared vectors in a local VM |
| Docker localnet stack | Splice 0.8.0; the participant's `/v2/version` reports Canton 3.5.16 | Splice's own `cluster/compose/localnet` tree at the Mainnet release, vendored under `localnet-overrides/splice-0.8.0/`; `check-compatibility.py`'s localnet row fails when Mainnet moves past it |
| Mainnet reference (pin dated 2026-09-22) | Splice 0.8.0 / Canton 3.5.16 / SDK 3.5.2 | Isolated local Ledger API matrix target; matches live mainnet, `check-compatibility.py` reports no drift |
| Testnet reference (pin dated 2026-09-22) | Splice 0.8.1 / Canton 3.5.17 / SDK 3.5.2 | Isolated local Ledger API matrix target; matches live testnet, `check-compatibility.py` reports no drift |

The live sources are the [mainnet status](https://docs.global.canton.network.sync.global/info), [mainnet compiler/runtime information](https://docs.global.canton.network.sync.global/app_dev/overview/version_information.html), [testnet status](https://docs.test.global.canton.network.sync.global/info), and [testnet compiler/runtime information](https://docs.test.global.canton.network.sync.global/app_dev/overview/version_information.html). Use `python3 scripts/check-compatibility.py` to detect drift; a dated pin is not a promise about future network versions.

The published DAR dependencies come from Splice release tag [`0.8.1`](https://github.com/canton-network/splice/tree/0.8.1), commit `fb3c8c8a9259e98cdeb1cffc0cc77eaa7cc69e52`. Its [Canton dependency settings](https://github.com/canton-network/splice/blob/0.8.1/project/CantonDependencies.scala) use Canton 3.5.15 and LF 2.1. [SPLICE_PIN](../../SPLICE_PIN) records all six published DAR checksums and package IDs. The interface package itself retains just its two specified Splice API dependencies.

## Executable proofs

**Result: PASS.** All 72 Daml Scripts in the suite passed on the IDE ledger and on both Canton 3.5.16 and 3.5.17. Both Solidity tests passed against the six shared vectors. Three Solana SBF tests also passed: both hash syscalls match those vectors, and malformed byte lengths and accidental hex-text inputs are rejected.

Run from the repository root:

```bash
./scripts/test.sh
./scripts/test-compatibility.sh
python3 scripts/check-compatibility.py
```

The normal suite has 72 Daml Scripts, two Solidity tests, and three Solana SBF tests. Each Canton runtime run uploads the DAR, exercises the real Ledger API, verifies the reported Canton version, checks that all core proofs ran, and writes `results.json`, `ledger-version.json`, and `evidence.json` under `.localnet/compatibility-<network>.*`. The core-proof check includes all six named worked examples, the eleven `TestPolicyLimits` policy-limit proofs, and the on-ledger preimage-count proof. Evidence includes the compiled package IDs and DAR hashes. The snapshot is [validation evidence](conditional-lock-validation-evidence.json).

| Required proof | Test and assertion |
| --- | --- |
| SHA-256 and Keccak match EVM byte-domain hashing | `TestHashVectors:test_hashVectorsMatchEvm`; six shared vectors, both Daml builtins and the policy helper, uppercase normalization; two Foundry tests use the same generated fixtures |
| The same byte domain works on Solana | `contracts/solana/tests/hash_vectors.rs` loads the compiled SBF program into LiteSVM, submits transactions, and compares both returned digests with the shared JSON; negative cases reject wrong lengths and hex text |
| Approver authority survives acceptance | `test_approverAuthorityPersistsAndAuthorizerDoesNotEnact`; Alice funds, Bob accepts separately, the arbiter alone enacts the hash rule, and an actual TestTokenV2 holding is created for Bob |
| Both actors can lock in one step | `test_oneStepBothActorsAndAuthorizerChange`; Alice and Bob act, no instruction remains, 100 is locked and 25 is returned from a 125 input; V1 and V2 views are checked |
| Atomic settlement of two instruments | `test_atomicDvpAcrossTwoTestTokenV2Registries`; X and Y have distinct admins and TokenRules, and one submission contains exactly two root Enact exercises |
| Atomic settlement also fails atomically | `test_atomicDvpRollsBackFirstEnactWhenSecondFails`; the second guard fails, both locks and backing holdings remain, neither payout exists, and the original contracts can then settle successfully together |
| The advertised limits are the enforced limits | `TestPolicyLimits:test_cipFloorsAreSatisfied`, `test_belowCipFloorIsRejected`, `test_limitsMetadataMatchesAdvertised`, `test_eachLimitKeyCarriesItsOwnField`, `test_limitsRoundTripThroughMetadata`, `test_limitsFromMetadataRejectsMalformed`, `test_witnessPreimageBoundIsEnforced`; the CIP section 3.8 floors, the eight-key factory `meta` pinned byte for byte, each key pinned to its own field by a profile whose eight values differ, the parsing inverse, and fail-closed parsing of a malformed or oversized advertisement |
| Every validator reads its bounds from its `Limits` argument | `TestPolicyLimits:test_pureValidatorsReadBoundsFromTheirArgument`, `test_legValidatorsReadBoundsFromTheirArgument`, `test_validateTermsReadsBoundsFromItsArgument`; each bound is exercised both below and above the reference value of 8, so reverting any validator to a literal fails |
| The witness preimage bound is enforced on a live lock | `TestRegistryLimits:test_preimageCountAtTheLimitIsAcceptedAndOverTheLimitRejected`; the over-limit witness still carries the correct preimage |

Additional proofs cover account-provider acceptance, sequential acceptance by multiple receivers, controller spoofing and duplicate threshold actors, rule consumption, conservation across partial releases and top-ups, bounded release, exact expiry, pending withdrawal, rejection, unanimous cancellation and amendment, prevention of spent-rule resurrection, malformed funding and terms and preimages, Keccak enactment, expired backing not spendable by the ordinary token path, both sides of V2 event reporting, two-alternative single firing, expiry always unlocking to the authorizer, combined fixed and enactor-supplied release legs, release and leg validation at creation and at amendment, leg identifier distinctness within and across locks, non-empty and forward-slash-free rule, leg, and lock identifiers, leg metadata on both transfer leg sides and reserved-key rejection, instruction and lock availableActions, authorizer-provider authorization at lock creation, the lock's signatory set, the rejection of enactor-supplied legs on an unlock, the eight advertised registry limits at and over each bound, and the enact and expire choice-observer functions.

### DvP between registries, against real Canton Coin

The 72-script suite settles two TestTokenV2 registries against each other, which proves the mechanics but not the integration. `pnpm test:integration` runs the same CIP-0112 section 4 example on the Mainnet-configuration localnet with a real counter-asset: TestTokenV2 locked under the conditional lock as the delivery leg, and **real Amulet** as the payment leg.

Both legs settle in one transaction. The executor submits two commands in a single `submit-and-wait-for-transaction` — `SettlementFactory_SettleBatch` on Splice's `ExternalPartyAmuletRules`, and `ConditionalLock_Enact` on the active lock — so the ledger records one update with two root nodes, one per leg. That is the atomicity claim, and it is checked against the participant's own re-read of the update rather than against what the harness submitted: the evidence gate recomputes the root nodes from `nodeId`/`lastDescendantNodeId` containment and refuses evidence that does not show exactly two.

The buyer is hosted on a second participant and approves the lock there, so the lock is genuinely cross-participant. Both counterparties allocate the Amulet leg — the buyer a sender-side allocation, the seller a receiver-side one — because Splice's batch settlement refuses a batch with any missing authorization; this mirrors CIP-0112 section 4.2.3, "Traders Accept Allocation Requests and Create Allocations". A second lock proves the expiry path under wall-clock time: after the deadline `ConditionalLock_Enact` is rejected because no alternative is satisfied, after `expiresAt` `ConditionalLock_Expire` returns the full amount to the seller unlocked, and the buyer withdraws his allocation and recovers the Amulet.

Evidence, regenerated from the run's own artifacts and never hand-edited, is at [localnet-mainnet-0.8.0-dvp-evidence.json](localnet-mainnet-0.8.0-dvp-evidence.json).

## Worked-example coverage

Daml Script tests for all six CIP section 4 worked examples live in [TestWorkedExamples.daml](../../packages/conditional-lock-test/daml/TestWorkedExamples.daml). Each named script combines the specified successful and rejected steps with holdings, lock-continuation, and V2 event assertions.

| CIP section 4 example | Named script | Mechanics proofs it relies on |
| --- | --- | --- |
| HTLC leg | `test_example_htlcLeg` | approver authority, expiry boundary, Keccak vs SHA-256, hash vectors |
| Escrowed DvP with a dispute window (`settle` path) | `test_example_dvpBetweenRegistries` | atomic two-registry DvP, rollback, threshold spoofing |
| Arbiter escrow | `test_example_arbiterEscrow` | release bounds, multiple receivers, expiry refund |
| Vesting | `test_example_vesting` | partial release conservation, spent-rule resurrection, guard boundaries (inclusive After, exclusive Before) |
| Collateral | `test_example_collateral` | unlock without acceptance, amend top-up, amend cannot change asset |
| Conditional payment | `test_example_conditionalPayment` | alternatives and guard boundaries (inclusive After, exclusive Before), enactor and threshold |

`test_example_dvpBetweenRegistries` exercises only the `settle` rule of the CIP's escrowed-DvP example: a two-party `Guard_Parties` guard enacted atomically across two registries, plus its rollback and threshold-spoofing failure paths. It does not exercise a dispute window, an arbiter, or the `award` rule. The full example, including the `award` path after the deadline, is exercised by [`examples/devnet-escrow/daml/EscrowedDvpDevNet.daml`](../../examples/devnet-escrow/daml/EscrowedDvpDevNet.daml) against a real wall-clock ledger; see [adoption-evidence.md](../adoption-evidence.md).

The HTLC script uses the first fixture, `zero`, for the basic SHA-256 claim and the exact-expiry refund. It uses `ascending-bytes`, whose hex encoding contains letters, to check case normalization and algorithm separation. The same preimage bytes must satisfy each algorithm's matching digest and fail against the other algorithm's digest. This makes the guard's algorithm selection observable while keeping the witness fixed.

| HTLC case | Fault the assertions detect |
| --- | --- |
| `zero`: wrong witness rejected, correct witness pays Bob | A guard that skips digest validation or releases to the wrong account |
| `zero`: claim rejected at exact expiry, Alice receives the refund | An inclusive claim-expiry boundary or an expiry refund that loses or redirects funds |
| `ascending-bytes`: uppercase witness accepted with matching SHA-256 and Keccak-256 digests | Rejection of uppercase hex, hashing hex text instead of decoded bytes, or selecting the wrong algorithm |
| `ascending-bytes`: SHA-256 with the Keccak-256 digest and Keccak-256 with the SHA-256 digest both reject the same witness; funds return at expiry | Ignoring the selected algorithm, accepting either digest, or consuming locked funds on a failed claim |

### Targeted fault injection

Seven deliberate faults were applied separately to temporary copies of the reference adapter. Every modified adapter compiled, and its selected worked-example script then failed at runtime on the IDE ledger. The checks left the working-tree adapter and interface source unchanged.

| Injected fault | Script that caught it |
| --- | --- |
| Remove preimage case normalization | `test_example_htlcLeg` |
| Accept either hash algorithm's digest regardless of the selected algorithm | `test_example_htlcLeg` |
| Make `Guard_After` strict, rejecting the boundary instant | `test_example_vesting` |
| Make `Guard_Before` inclusive, accepting the deadline instant | `test_example_conditionalPayment` |
| Remove the release receiver allow-list check | `test_example_arbiterEscrow` |
| Remove amendment funding conservation | `test_example_collateral` |
| Report the wrong receiver side in a transfer event | `test_example_dvpBetweenRegistries` |

The `worked_example_mutations` section of the [validation evidence](conditional-lock-validation-evidence.json) records the exact replacements, commands, and observed errors. That snapshot predates the split of the policy evaluator into `conditional-lock-utils`: five of its seven recorded `source` paths still name `packages/conditional-lock-test-token/daml/ConditionalLock/Policy.daml`, and the file now lives at `packages/conditional-lock-utils/daml/ConditionalLock/Policy.daml`. Each recorded `before` snippet is still present there verbatim. The snapshot also records three artifacts where the run now produces four. It is regenerated by a full mutation campaign, not by `test-compatibility.sh`, so it is left as the historical record of the run it describes. To reproduce a check, apply its recorded replacement in a temporary copy of the repository, rebuild the policy and adapter packages, and run the named script from the test package:

```bash
cd packages/conditional-lock-utils
dpm build
cd ../conditional-lock-test-token
dpm build
cd ../conditional-lock-test
dpm test --files daml/TestWorkedExamples.daml -p 'test_example_<name>'
```

Substitute the script suffix from the table for `<name>`. These checks provide targeted sensitivity evidence for the seven listed faults; exhaustive mutation coverage was not measured.

## Implementation decisions

`conditional-lock-test-token` is first-party code compiled against the published `splice-test-token-v2-1.0.1.dar`. It consumes and creates the real `Splice.Testing.Tokens.TestTokenV2.Holding.Token` template; it does not substitute an unrelated mock token or copy Splice source.

An instruction is signed by the registry admin, authorizer account parties, and approver account parties that have already approved. Each acceptance consumes that instruction and its backing and recreates both with the newly accepted parties as signatories. The active lock carries those signatures forward. Its exercise context can therefore authorize the backing's consumption and receiver holdings without asking the authorizer or approver to sign again. The arbiter-only proof gives the enactor neither authorizer/admin `actAs` nor authorizer/admin `readAs` privileges.

The backing implements Holding V1, Holding V2, and EventLog V2. Enact, expiry, and withdrawal log their changes before archiving it in the same transaction. This avoids a dependency on a private TokenRules contract that might be invisible to an enactor. The EventLog choice is controlled by the instrument admin, whose authority is already held by the policy contract.

The backing is a separate template rather than an ordinary TestTokenV2 token marked with an expired lock. It becomes unlocked funds of the authorizer only through the package's own choices, never through the generic token-spending path, including after expiry. This is a deliberate deviation from CIP section 3.6, which says registries SHOULD accept holdings whose lock has expired as transfer inputs; here `ConditionalLock_Expire` runs first. Its views still show the authorizer's account, amount, named holders, absolute expiry, and lock-context metadata.

Factories are single-use registry-issued offers with a stable lock ID. The admin MUST issue distinct IDs, just as the admin is trusted to issue TestTokenV2 supply correctly. This reference registry requires both account owner and provider when present; it does not implement TestTokenV2's configurable account authorization state machine or standing preapprovals.

## Draft corrections established by implementation

Two narrow corrections are included in the CIP:

1. The Cancel choice comment now permits cancellation after expiry, matching the Security Considerations. Consent remains unanimous.
2. Transfer event IDs are `<lockId>/<ruleId>/<legId>`, where the third component is the leg's own identifier, chosen by the terms author for a fixed leg and by the enactor for a supplied leg. The previous `<lockId>/<ruleId>` alone assigned identical IDs to different legs of one enactment, violating CIP-0112's distinct-leg requirement. A rule ID fires at most once per lock ID and leg IDs are unique within an enactment, so no revision component is needed. All three components MUST be non-empty and MUST NOT contain `/`. Both sides of each leg still share an ID. The registry MUST issue distinct lock IDs.

## Scope of the compatibility claim

The proofs establish compilation and execution of these Daml contracts on the current network runtime versions. The 72-script suite's topology is one participant and one synchronizer with controlled ledger time.

The DvP integration test (`pnpm test:integration`) extends that in three specific directions, and the scope statement has to be read against it. It runs on the Mainnet-configuration localnet across **two participants** under **wall-clock** time: the seller and the registry admin on app-provider, the buyer on app-user, with the buyer approving the lock on his own participant and the settlement confirmed across both. It is therefore a **multi-participant** proof, not a single-participant one. It also exercises **Splice wallet and registry integration** directly — the validator wallet API for the tap, the balance, and the V2 Amulet allocations, and scan's `/registry/allocation/v2/settlement-factory` for the settlement factory and its choice context.

What it still does not establish: a public-network deployment; network traffic economics; production authentication (the localnet's credentials are the unsafe HS256 secret Splice ships plus the fixed participant admin token this repository pins, neither of which resembles a real deployment's); or external signing — the harness deliberately avoids it by naming one executor party hosted on the submitting participant, which is the design choice [localnet.md](localnet.md) explains.

The Solana addition is a local hash compatibility proof using pinned Agave runtime dependencies. It does not implement a token escrow or validate a live Solana cluster's feature set. See the [hash-vector runbook](hash-vectors.md#solana-proof) for the exact program input, output, and toolchain.

A production registry still needs its account controls, pause/allow-list behavior, HTTP choice contexts, distinct-ID issuance, and the full token-standard conformance suite.

On Canton Coin, the earlier statement that it "requires the planned LockedAmulet/ExternalPartyAmuletRules and CIP-0107 work" is now half true and should be read as two claims. **Settling against Amulet needs no further work**: the DvP integration test moves real DSO-issued Amulet through Splice's own `ExternalPartyAmuletRules` settlement factory, in the same transaction that enacts a conditional lock over TestTokenV2, on the release Mainnet runs. **Locking Amulet itself still does**: Amulet has no `ConditionalLock` implementation, the locked asset in every proof here is a non-Amulet registry's, and that part follows Splice's own track.
