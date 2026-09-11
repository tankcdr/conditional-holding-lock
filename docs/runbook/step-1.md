# Step 1: compilation, authority, and atomicity

Evaluation date: **September 11, 2026**. Scope: the first implementation milestone in the week-of-September-14 plan. The private outreach, standards sponsorship, registry HTTP endpoints, wallet integration, and Canton Coin implementation are later work.

## Environment and compatibility

| Component | Observed configuration | Assessment |
| --- | --- | --- |
| Compiler | DPM 1.0.21; SDK 3.5.2 | Matches Splice main and both network references |
| First-party language target | LF 2.1; explicit serializability | Matches the V2 packages; no development LF target |
| Java | Global JDK 26; project tests select installed JDK 21 | Tests no longer depend on an unsupported global Java or stale `JAVA_HOME` |
| Foundry | 1.3.6, Solidity 0.8.24 | Both byte-domain hash algorithms tested |
| Solana | Agave CLI/runtime dependencies 3.1.14, platform-tools v1.52, Rust 1.89.0, LiteSVM 0.9.1 | Compiled SBF program matches both hashes on the shared vectors in a local VM |
| Existing shared Docker stack | Splice 0.6.7; Canton image 0.6.8 reports engine 3.5.4 | Older than the networks; owned by another checkout and left running |
| Mainnet reference | Splice 0.7.4 / Canton 3.5.14 / SDK 3.5.2 | Isolated local Ledger API matrix target |
| Testnet reference | Splice 0.7.5 / Canton 3.5.15 / SDK 3.5.2 | Isolated local Ledger API matrix target |

The live sources are the [mainnet status](https://docs.global.canton.network.sync.global/info), [mainnet compiler/runtime information](https://docs.global.canton.network.sync.global/app_dev/overview/version_information.html), [testnet status](https://docs.test.global.canton.network.sync.global/info), and [testnet compiler/runtime information](https://docs.test.global.canton.network.sync.global/app_dev/overview/version_information.html). Use `python3 scripts/check-compatibility.py` to detect drift; a dated pin is not a promise about future network versions.

The published DAR dependencies come from Splice main commit [`6b82367efb9ca6f94ced604ef9350280d05b334c`](https://github.com/canton-network/splice/tree/6b82367efb9ca6f94ced604ef9350280d05b334c). Its [Canton dependency settings](https://github.com/canton-network/splice/blob/6b82367efb9ca6f94ced604ef9350280d05b334c/project/CantonDependencies.scala) use Canton 3.5.15 and LF 2.1. [SPLICE_PIN](../../SPLICE_PIN) records all six published DAR checksums and package IDs. The interface package itself retains just its two specified Splice API dependencies.

## Executable proofs

**Result: PASS.** All 23 Daml Scripts passed on the IDE ledger and on both Canton 3.5.14 and 3.5.15. Both Solidity tests passed against the six shared vectors. Three Solana SBF tests also passed: both hash syscalls match those vectors, and malformed byte lengths and accidental hex-text inputs are rejected.

Run from the repository root:

```bash
./scripts/test.sh
./scripts/test-compatibility.sh
python3 scripts/check-compatibility.py
```

The normal suite has 23 Daml Scripts, two Solidity tests, and three Solana SBF tests. Each Canton runtime run uploads the DAR, exercises the real Ledger API, verifies the reported Canton version, checks that all core proofs ran, and writes `results.json`, `ledger-version.json`, and `evidence.json` under `.localnet/compatibility-<network>.*`. Evidence includes the compiled package IDs and DAR hashes. The snapshot is [step-1-evidence.json](step-1-evidence.json).

| Required proof | Test and assertion |
| --- | --- |
| SHA-256 and Keccak match EVM byte-domain hashing | `TestHashVectors:test_hashVectorsMatchEvm`; six shared vectors, both Daml builtins and the policy helper, uppercase normalization; two Foundry tests use the same generated fixtures |
| The same byte domain works on Solana | `contracts/solana/tests/hash_vectors.rs` loads the compiled SBF program into LiteSVM, submits transactions, and compares both returned digests with the shared JSON; negative cases reject wrong lengths and hex text |
| Receiver authority survives acceptance | `test_receiverAuthorityPersistsAndOwnerDoesNotEnact`; Alice funds, Bob accepts separately, the arbiter alone enacts the hash rule, and an actual TestTokenV2 holding is created for Bob |
| Both actors can lock in one step | `test_oneStepBothActorsAndOwnerChange`; Alice and Bob act, no instruction remains, 100 is locked and 25 is returned from a 125 input; V1 and V2 views are checked |
| Atomic settlement of two instruments | `test_atomicDvpAcrossTwoTestTokenV2Registries`; X and Y have distinct admins and TokenRules, and one submission contains exactly two root Enact exercises |
| Atomic settlement also fails atomically | `test_atomicDvpRollsBackFirstEnactWhenSecondFails`; the second guard fails, both locks and backing holdings remain, neither payout exists, and the original contracts can then settle successfully together |

Additional proofs cover account-provider acceptance, sequential acceptance by multiple receivers, controller spoofing and duplicate threshold actors, rule consumption, conservation across partial releases and top-ups, bounded distribution, exact expiry, pending withdrawal, rejection, unanimous cancellation/amendment, prevention of spent-rule resurrection, malformed funding/terms/preimages, Keccak enactment, repeated partial fallbacks, and both sides of V2 event reporting.

## Implementation decisions

`conditional-lock-test-token` is first-party code compiled against the published `splice-test-token-v2-1.0.1.dar`. It consumes and creates the real `Splice.Testing.Tokens.TestTokenV2.Holding.Token` template; it does not substitute an unrelated mock token or copy Splice source.

An instruction is signed by the registry admin, owner account parties, and receiver account parties that have already accepted. Each acceptance consumes that instruction and its backing and recreates both with the newly accepted parties as signatories. The active lock carries those signatures forward. Its exercise context can therefore authorize the backing's consumption and receiver holdings without asking the owner or receiver to sign again. The arbiter-only proof gives the enactor neither owner/admin `actAs` nor owner/admin `readAs` privileges.

The backing implements Holding V1, Holding V2, and EventLog V2. Enact, expiry, and withdrawal log their changes before archiving it in the same transaction. This avoids a dependency on a private TokenRules contract that might be invisible to an enactor. The EventLog choice is controlled by the instrument admin, whose authority is already held by the policy contract.

The backing is a separate template rather than an ordinary TestTokenV2 token marked with an expired lock. This prevents the generic token-spending path from bypassing a conditional fallback after expiry. Its views still show the original owner, amount, named holders, absolute expiry, and lock-context metadata.

Factories are single-use registry-issued offers with a stable lock ID. The admin must issue distinct IDs, just as the admin is trusted to issue TestTokenV2 supply correctly. This reference registry requires both account owner and provider when present; it does not implement TestTokenV2's configurable account authorization state machine or standing preapprovals.

## Draft corrections established by implementation

Two narrow corrections are included in the CIP:

1. The Cancel choice comment now permits cancellation after expiry, matching sections 3.6 and Security Considerations. Consent remains unanimous.
2. Transfer event IDs include revision and leg-index suffixes. The previous `<lockId>/<ruleId>` alone assigned identical IDs to different legs and repeated fallbacks, violating CIP-0112's distinct-leg requirement. Both sides of each leg still share an ID. The registry's responsibility to issue distinct lock IDs is explicit.

## Scope of the compatibility claim

The proofs establish compilation and execution of these Daml contracts on the current network runtime versions. The test topology has one participant and one synchronizer with controlled ledger time. It does not establish a public-network deployment, multi-participant operational behavior, network traffic economics, production authentication, external signing, or Splice wallet/registry integration.

The Solana addition is a local hash compatibility proof using pinned Agave runtime dependencies. It does not implement a token escrow or validate a live Solana cluster's feature set. See the [hash-vector runbook](hash-vectors.md#solana-proof) for the exact program input, output, and toolchain.

The original shared Docker topology is still old and must not be described as mainnet-equivalent. Use the isolated matrix for this milestone. A production registry still needs its account controls, pause/allow-list behavior, HTTP choice contexts, distinct-ID issuance, and the full token-standard conformance suite. Canton Coin requires the planned LockedAmulet/ExternalPartyAmuletRules and CIP-0107 work. No outreach or subscriptions were performed as part of this implementation milestone.
