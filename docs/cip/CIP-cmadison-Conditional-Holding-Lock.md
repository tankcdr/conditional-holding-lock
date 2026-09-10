---
CIP: ?
Layer: Daml
Title: Conditional Holding Lock
Author: Chris Madison
Status: Draft
Type: Standards Track
Created: 2026-09-10
License: CC0-1.0
Requires: CIP-0056, CIP-0112
---

# Abstract

This CIP adds one interface package to the Canton Network Token Standard,
`splice-api-token-conditional-lock-v1`, that lets the owner of a Holding attach
a release policy to it. A conditional lock is a set of rules; each rule pairs a
guard the ledger can check (hash preimage, ledger time before or after a point,
a threshold of named parties, or a bounded combination of these) with an
outcome the ledger enacts (unlock to the owner, transfer to fixed legs, or
distribute among a fixed set of receivers). Rules fire at most once and may
consume part of the locked amount, in which case the lock continues with the
remainder. Every lock has an expiry and a fallback outcome that only the owner
can enact once the expiry passes.

The package does not modify any existing token standard package. Guard
evaluation and conservation checks live in `splice-token-standard-utils`
(`Splice.TokenStandard.Utils.Internal.ConditionalLocks`) so every registry
evaluates a given `LockTerms` the same way. That is a conformance property of
this CIP.

# Confirmed on Splice main (SDK 3.5.2, Daml-LF 2.1)

Before posting:

1. `DA.Crypto.Text.sha256` and `keccak256` match EVM `sha256(bytes32)` and
   `keccak256(bytes32)` on the shared vectors in `fixtures/hash-vectors.json`.
2. Receiver authority is captured at lock/accept time. `ConditionalLock_Enact`
   succeeds when only the receiver/enactor signs; the owner is not a submitter.
3. A one-step lock returns `ConditionalLockResult_Locked` when both parties are
   among `actors`.
4. Two `Enact` choices on two TestTokenV2 instruments (two registry admins)
   commit atomically in one transaction. A submission missing a required actor
   leaves both locks intact.

# Specification

The interface text is the Daml module
`Splice.Api.Token.ConditionalLockV1` in
`splice/token-standard/splice-api-token-conditional-lock-v1/`. Build settings
match the existing V2 packages (`sdk-version: 3.5.2`, `--target=2.1`,
`--explicit-serializable=yes`). Dependencies are `splice-api-token-metadata-v1`
and `splice-api-token-holding-v2`.

Preimages are 32 raw bytes, hex-encoded lowercase. Digests are computed over
the decoded bytes, not over the hex text, so the same preimage satisfies an EVM
`sha256(bytes32)` or `keccak256(bytes32)` lock. Registries MUST support both
algorithms.

# Reference implementation

Apache-2.0, this repository:

- API package, utils evaluator, TestTokenV2 factory/instruction/lock
- Daml Script tests for the four confirmations above
- EVM `HashVectors.sol` sharing the same fixtures
- OpenAPI `conditional-lock-v1.yaml`

Canton Coin (`LockedAmulet`) and the Splice wallet UI are follow-on work.

# Copyright

This CIP is licensed under CC0-1.0. Code in the reference implementation is
licensed under Apache-2.0.
