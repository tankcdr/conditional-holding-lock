# CIP-TBD-Conditional-Holding-Lock

<pre>
  CIP: TBD
  Layer: Daml
  Title: Conditional Holding Lock
  Author: Chris Madison <[email]>
  Status: Draft
  Type: Standards Track
  Created: 2026-09-10
  License: CC0-1.0
  Requires: CIP-0056, CIP-0112
  Post-History: [cip-discuss thread link]
</pre>

## Abstract

This CIP adds one interface package to the Canton Network Token Standard, `splice-api-token-conditional-lock-v1`, that lets the owner of a `Holding` attach a release policy to it. A conditional lock is a set of rules; each rule pairs a guard the ledger can check (hash preimage, ledger time before or after a point, a threshold of named parties, or a bounded combination of these) with an outcome the ledger enacts (unlock to the owner, transfer to fixed legs, or distribute among a fixed set of receivers). Rules fire at most once and may consume part of the locked amount, in which case the lock continues with the remainder. Every lock has an expiry and a fallback outcome that only the owner can enact once the expiry passes. The owner and every party named in the terms can cancel or amend by unanimous consent.

The package defines a factory, a two-step instruction for receiver acceptance, the lock interface with `Enact`, `Expire`, `Cancel`, and `Amend` choices, the holding representation while locked, event reporting through the CIP-0112 `EventLog`, and the off-ledger registry endpoints wallets use to obtain factory and choice contexts. It does not modify any existing token standard package. Any registry can implement it; any V1 or V2 wallet already displays the locked holding correctly.

The primitive expresses hash time-locked atomic swaps with external chains, executor-free delivery versus payment between Canton registries, escrow with an arbiter, vesting and tranche release, collateral with top-up, and conditional or deferred payments, all as an attribute of the holding rather than a transfer of title.

## Motivation

The token standard describes locks but does not let anyone create one. `Holding.lock` in CIP-0056 and CIP-0112 is view data: `holders`, `expiresAt`, `expiresAfter`, `context`. There is no standard choice that locks a holding, no standard statement of who may release it, and no standard condition under which release is permitted. Canton Coin exposes a registry-specific `LockedAmulet` whose unlock requires the owner and every lock holder to act together, with a timeout for the owner. No other registry is obliged to offer anything comparable, and an application cannot write one lock flow that works across registries.

Allocations in CIP-0112 cover venue settlement, not conditional release. Settlement is authorized by trusted `executors`, funds are committed to fixed transfer legs, and the counterparties rely on the executors to settle or cancel. That is the right model for a venue. It is the wrong model when the release authority is a fact rather than a party: knowledge of a preimage, the passage of time, or the decision of an arbiter who is not the venue. It is also the wrong model for locks with more than one possible outcome, such as escrow, vesting, and collateral.

The gap is most visible in cross-chain settlement. A hash time-locked contract on an EVM or Bitcoin chain is only atomic if the other leg is released by the same preimage on-ledger. Without a standard Canton-side hashlock, Canton legs of atomic swaps are today either registry-specific contracts that no wallet understands, or an executor who promises to settle when shown the preimage off-ledger. Both replace atomicity with trust.

Canton can express the general primitive more cleanly than account-model chains. A lock is an attribute of the holding, so the funds never leave the owner's account or portfolio view. The release paths are pre-authorized by the owner when the lock is created, so a receiver or an arbiter can enact a rule without the owner's signature at that time. Visibility is confined to the lock's stakeholders. And because Daml transactions are atomic across contracts, two locks can be enacted in one transaction, which gives delivery versus payment between any two registries with no executor and no hashlock. This CIP standardizes that pattern so that wallets, registries, and applications interoperate on it.

## Specification

### 1. Package

New Daml package `splice-api-token-conditional-lock-v1`, module `Splice.Api.Token.ConditionalLockV1`. Dependencies: `splice-api-token-metadata-v1` and `splice-api-token-holding-v2`. Build settings match the existing V2 packages (Daml-LF 2.1, explicit serializability). The package is added to the `token-standard` directory of Splice under the same license and versioning practice as the CIP-0112 packages.

### 2. Data types

```daml
module Splice.Api.Token.ConditionalLockV1 where

import Splice.Api.Token.MetadataV1
import Splice.Api.Token.HoldingV2

-- | Hash function for a hashlock. Digests and preimages are hex-encoded byte strings.
data HashAlgorithm
  = Sha256
    -- ^ SHA-256 over the raw preimage bytes. Registries MUST support this algorithm.
  | Keccak256
    -- ^ Keccak-256 over the raw preimage bytes. Registries MUST support this algorithm.
  deriving (Eq, Ord, Show, Serializable)

-- | A condition the ledger can check when a rule is enacted.
data Guard
  = Guard_Preimage with
      algorithm : HashAlgorithm
      digest : Text
        -- ^ Lowercase hex-encoded digest. Satisfied by a 32-byte preimage in the witness
        -- whose digest under `algorithm` equals this value.
  | Guard_After with
      time : Time
        -- ^ Satisfied when ledger time is at or after `time`.
  | Guard_Before with
      time : Time
        -- ^ Satisfied when ledger time is strictly before `time`.
  | Guard_Parties with
      parties : [Party]
        -- ^ Unique list of parties.
      threshold : Int
        -- ^ Satisfied when at least `threshold` of `parties` are among the enacting actors.
        -- MUST satisfy 1 <= threshold <= length parties.
  | Guard_All with
      guards : [Guard]
        -- ^ Satisfied when every guard is satisfied. MUST be non-empty.
  | Guard_Any with
      guards : [Guard]
        -- ^ Satisfied when at least one guard is satisfied. MUST be non-empty.
  deriving (Eq, Ord, Show, Serializable)

-- | Evidence supplied when enacting a rule.
data Witness = Witness with
    preimages : [Text]
      -- ^ Hex-encoded 32-byte preimages. Each `Guard_Preimage` node is satisfied if any
      -- listed preimage hashes to its digest.
  deriving (Eq, Ord, Show, Serializable)

-- | A destination for locked funds.
data Leg = Leg with
    receiver : Account
    amount : Decimal
      -- ^ MUST be positive.
  deriving (Eq, Ord, Show, Serializable)

-- | What happens to the locked funds when a rule fires.
data Outcome
  = Outcome_Unlock
    -- ^ The full remaining amount returns to the owner, unlocked. Terminates the lock.
  | Outcome_Transfer with
      legs : [Leg]
        -- ^ Fixed legs. Sum MUST be at most the remaining amount. A leg whose receiver is
        -- the owner account returns that amount unlocked. Any remainder stays locked.
  | Outcome_Distribute with
      receivers : [Account]
        -- ^ Legs are supplied by the enactor when the rule fires. Each leg's receiver MUST
        -- be in this list; the sum MUST be at most the remaining amount. Any remainder
        -- stays locked.
  deriving (Eq, Ord, Show, Serializable)

-- | One release path.
data Rule = Rule with
    id : Text
      -- ^ Unique within the terms. Reported in events.
    enactors : [Party]
      -- ^ Parties entitled to enact this rule. At least one MUST be among the actors.
    guard : Guard
    outcome : Outcome
  deriving (Eq, Ord, Show, Serializable)

-- | The release policy, provided by the owner's wallet.
data LockTerms = LockTerms with
    owner : Account
      -- ^ Account whose holdings fund the lock and to which unlocked funds return.
    instrumentId : InstrumentId
    amount : Decimal
      -- ^ Locked amount. On a continuation, the remaining amount.
    rules : [Rule]
      -- ^ Enactable strictly before `expiresAt`. Each fires at most once.
    expiresAt : Time
      -- ^ Absolute, inclusive ledger time at which the rules stop being enactable and
      -- the fallback becomes enactable.
    fallback : Outcome
      -- ^ Enactable by the owner at or after `expiresAt`. Typically `Outcome_Unlock`.
    requestedAt : Time
      -- ^ Wallet-provided creation timestamp. MUST be in the past when locking.
    meta : Metadata
      -- ^ Metadata for extensibility. SHOULD carry
      -- `splice.lfdecentralizedtrust.org/lock-context`.
  deriving (Eq, Show, Serializable)

-- | Result of instructing, enacting, expiring, cancelling, or amending a lock.
data ConditionalLockResult = ConditionalLockResult with
    output : ConditionalLockResult_Output
    meta : Metadata
      -- ^ Implementation-specific metadata, e.g. fees charged.
  deriving (Eq, Show, Serializable)

data ConditionalLockResult_Output
  = ConditionalLockResult_Pending with
      instructionCid : ContractId ConditionalLockInstruction
        -- ^ One or more receivers must accept before the lock becomes active.
  | ConditionalLockResult_Locked with
      lockCid : ContractId ConditionalLock
      holdingCid : ContractId Holding
        -- ^ The locked holding backing the lock.
      ownerChangeCids : [ContractId Holding]
        -- ^ Change returned to the owner from the input holdings.
  | ConditionalLockResult_Enacted with
      receiverHoldingCids : [ContractId Holding]
        -- ^ Holdings created for receivers other than the owner.
      ownerHoldingCids : [ContractId Holding]
        -- ^ Unlocked holdings returned to the owner.
      continuationCid : Optional (ContractId ConditionalLock)
        -- ^ The continuing lock, when funds remain.
  | ConditionalLockResult_Failed
      -- ^ Instruction rejected or withdrawn; input holdings unlocked.
  deriving (Eq, Show, Serializable)
```

### 3. Interfaces

#### 3.1 `ConditionalLockFactory`

```daml
data ConditionalLockFactoryView = ConditionalLockFactoryView with
    admin : Party
      -- ^ Registry admin for the instruments this factory serves.
    meta : Metadata
      -- ^ MUST carry the registry's limits (see 3.8).
  deriving (Eq, Show, Serializable)

interface ConditionalLockFactory where
  viewtype ConditionalLockFactoryView

  conditionalLockFactory_lockExtraObservers : ConditionalLockFactory_Lock -> [Party]
  conditionalLockFactory_lockImpl : ContractId ConditionalLockFactory -> ConditionalLockFactory_Lock -> Update ConditionalLockResult
  conditionalLockFactory_publicFetchImpl : ContractId ConditionalLockFactory -> ConditionalLockFactory_PublicFetch -> Update ConditionalLockFactoryView

  nonconsuming choice ConditionalLockFactory_Lock : ConditionalLockResult
    -- ^ Lock `terms.amount` of the owner's holdings under `terms`.
    with
      terms : LockTerms
      inputHoldingCids : [ContractId Holding]
        -- ^ Holdings funding the lock. Same rules as `Transfer.inputHoldingCids` in CIP-0112.
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of `terms.owner`.
      extraArgs : ExtraArgs
    observer conditionalLockFactory_lockExtraObservers this arg
    controller actors
    do conditionalLockFactory_lockImpl this self arg

  nonconsuming choice ConditionalLockFactory_PublicFetch : ConditionalLockFactoryView
    with
      actors : [Party]
    controller actors
    do conditionalLockFactory_publicFetchImpl this self arg
```

Rules:

- The factory MUST validate the terms: `instrumentId.admin` equals the factory `admin`; `requestedAt` is in the past; `expiresAt` is in the future; `amount` is positive; rule ids are unique; every guard is well-formed (digests are lowercase hex of the algorithm's digest length; thresholds are in range; `Guard_All` and `Guard_Any` are non-empty); every `Outcome_Transfer` has positive legs summing to at most `amount`; every `Outcome_Distribute` has a non-empty, unique receiver list; every rule has at least one enactor; the terms are within the registry's advertised limits.
- The **receivers** of the terms are the accounts, other than `terms.owner`, appearing as `Leg.receiver` in any `Outcome_Transfer` or in any `Outcome_Distribute.receivers`, in the rules or the fallback. The **named parties** of the terms are the parties of every receiver account plus all enactors and all `Guard_Parties` members, excluding the parties of `terms.owner`.
- If for every receiver the `actors` include the parties the registry requires to create holdings for it, or the receiver holds a standing pre-approval the registry recognizes, the factory SHOULD complete in one step and return `ConditionalLockResult_Locked`.
- Otherwise the factory MUST return `ConditionalLockResult_Pending` with a `ConditionalLockInstruction`. Input holdings SHOULD be locked to the owner and the named parties while the instruction is pending, with `expiresAt` set to `terms.expiresAt`.

#### 3.2 `ConditionalLockInstruction`

```daml
data ConditionalLockInstructionView = ConditionalLockInstructionView with
    terms : LockTerms
    pendingReceivers : [Account]
      -- ^ Receivers that have not yet accepted.
    meta : Metadata
  deriving (Eq, Show, Serializable)

interface ConditionalLockInstruction where
  viewtype ConditionalLockInstructionView

  conditionalLockInstruction_acceptImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Accept -> Update ConditionalLockResult
  conditionalLockInstruction_rejectImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Reject -> Update ConditionalLockResult
  conditionalLockInstruction_withdrawImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Withdraw -> Update ConditionalLockResult

  nonconsuming choice ConditionalLockInstruction_Accept : ConditionalLockResult
    -- ^ A receiver accepts. Result is `Locked` once every receiver has accepted,
    -- otherwise `Pending`.
    with
      receiver : Account
      actors : [Party]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLockInstruction_acceptImpl this self arg

  nonconsuming choice ConditionalLockInstruction_Reject : ConditionalLockResult
    -- ^ A receiver declines. Result is `Failed`; input holdings return to the owner unlocked.
    with
      receiver : Account
      actors : [Party]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLockInstruction_rejectImpl this self arg

  nonconsuming choice ConditionalLockInstruction_Withdraw : ConditionalLockResult
    -- ^ Owner withdraws before all receivers have accepted. Result is `Failed`.
    with
      actors : [Party]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLockInstruction_withdrawImpl this self arg
```

Registries MUST allow the owner to withdraw a pending instruction at or after `terms.expiresAt` regardless of receiver action, so pending instructions cannot pin funds indefinitely.

#### 3.3 `ConditionalLock`

```daml
data ConditionalLockView = ConditionalLockView with
    lockId : Text
      -- ^ Stable across continuations and amendments. Reported in events.
    terms : LockTerms
      -- ^ Current terms: remaining amount and remaining rules.
    holdingCid : ContractId Holding
      -- ^ The locked holding backing this lock.
    meta : Metadata
  deriving (Eq, Show, Serializable)

interface ConditionalLock where
  viewtype ConditionalLockView

  conditionalLock_enactImpl : ContractId ConditionalLock -> ConditionalLock_Enact -> Update ConditionalLockResult
  conditionalLock_expireImpl : ContractId ConditionalLock -> ConditionalLock_Expire -> Update ConditionalLockResult
  conditionalLock_cancelImpl : ContractId ConditionalLock -> ConditionalLock_Cancel -> Update ConditionalLockResult
  conditionalLock_amendImpl : ContractId ConditionalLock -> ConditionalLock_Amend -> Update ConditionalLockResult

  nonconsuming choice ConditionalLock_Enact : ConditionalLockResult
    -- ^ Fire one rule. MUST fail at or after `terms.expiresAt`, unless at least one of
    -- the rule's enactors is among `actors`, unless the guard is satisfied (3.5), or
    -- unless `legs` are valid for the outcome (3.6).
    with
      ruleId : Text
      actors : [Party]
      witness : Witness
      legs : Optional [Leg]
        -- ^ MUST be provided for `Outcome_Distribute` and MUST be `None` otherwise.
      extraArgs : ExtraArgs
    controller actors
    do conditionalLock_enactImpl this self arg

  nonconsuming choice ConditionalLock_Expire : ConditionalLockResult
    -- ^ Enact the fallback. MUST fail before `terms.expiresAt`.
    with
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of the
        -- owner account. Registries MAY additionally permit the admin alone.
      legs : Optional [Leg]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLock_expireImpl this self arg

  nonconsuming choice ConditionalLock_Cancel : ConditionalLockResult
    -- ^ Return the full remaining amount to the owner unlocked, including after expiry, with the
    -- consent of every named party.
    with
      actors : [Party]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLock_cancelImpl this self arg

  nonconsuming choice ConditionalLock_Amend : ConditionalLockResult
    -- ^ Replace the terms, optionally adding funds, with the consent of every named party
    -- of the current terms and the owner. Result is `Locked` with the new lock, or
    -- `Pending` if the new terms introduce receivers that must accept.
    with
      newTerms : LockTerms
      additionalInputHoldingCids : [ContractId Holding]
      actors : [Party]
      extraArgs : ExtraArgs
    controller actors
    do conditionalLock_amendImpl this self arg
```

The choices are nonconsuming, following CIP-0112, so that implementations control consumption. On success, implementations MUST archive the `ConditionalLock` and the backing holding in the same transaction, creating a continuation lock and holding when funds remain.

#### 3.4 Holding representation while locked

While a lock is active the registry MUST represent the funds as a `Holding` in `terms.owner` with `amount = terms.amount` and `lock` set to:

- `holders`: the named parties of the terms;
- `expiresAt = Some terms.expiresAt`;
- `expiresAfter = None`;
- `context`: a short human-readable description, for example `hashlock to <receiver>`, `escrow, arbiter <party>`, or `vesting, 4 tranches`.

The holding's `meta` MUST carry `splice.lfdecentralizedtrust.org/lock-context` with the same text. The `ConditionalLock` interface MAY be implemented by the same contract as the `Holding`, as `LockedAmulet` does, or by a separate contract referencing it.

This is what makes the CIP invisible to existing wallets: a conditionally locked holding is a locked holding, and CIP-0056 and CIP-0112 wallets already render those.

#### 3.5 Guard evaluation

Guards are evaluated at enactment against ledger time, the `witness`, and the `actors`:

- `Guard_Preimage`: satisfied if some entry of `witness.preimages`, lowercased, is exactly 32 bytes of hex and its digest under `algorithm`, computed with `DA.Crypto.Text.sha256` or `DA.Crypto.Text.keccak256`, equals `digest`. The digest is computed over the decoded bytes, not over the hex text, so the same preimage satisfies an EVM `sha256(bytes32)` or a Bitcoin `OP_SHA256` lock.
- `Guard_After`: satisfied if ledger time is at or after `time`.
- `Guard_Before`: satisfied if ledger time is strictly before `time`.
- `Guard_Parties`: satisfied if at least `threshold` distinct members of `parties` are among `actors`.
- `Guard_All`, `Guard_Any`: conjunction and disjunction of their children.

Registries MUST support all guard kinds and nesting to at least depth 3 (a leaf under a combinator under a combinator). Guards are a closed set: there is no arithmetic, no reference to other contracts, and no repetition. Composition beyond nesting is out of scope for V1.

#### 3.6 Outcome enactment and continuation

On `Enact` of rule `r` with remaining amount `a`:

- `Outcome_Unlock`: `a` returns to the owner unlocked; the lock terminates.
- `Outcome_Transfer`: for each leg, a holding of `leg.amount` is created in `leg.receiver` (unlocked in the owner account if the receiver is the owner). If the legs sum to less than `a`, the lock continues with amount `a - sum` and rules `terms.rules` minus `r`. Otherwise it terminates. If the legs sum to more than `a` (possible after earlier partial consumption), the enactment MUST fail.
- `Outcome_Distribute`: as `Outcome_Transfer` using the enactor-supplied `legs`, which MUST each name a receiver in `receivers`, have positive amount, and sum to at most `a`.

`Expire` applies the same rules to `terms.fallback`; a continuation after `Expire` keeps the fallback and no rules, and remains enactable only through `Expire` and `Cancel`.

Creation of receiver holdings is a transfer: registry rules that apply to transfers into the receiver account (allow lists, pause status, account provider controls) apply to enactment. Registries MAY fail an enactment for those reasons. They MUST NOT fail an `Expire` whose fallback is `Outcome_Unlock` for reasons attributable to any party other than the owner.

`Cancel` requires the parties the registry requires to move funds out of the owner account plus every named party of the current terms. `Amend` requires the same, and additionally: `newTerms.owner` and `newTerms.instrumentId` MUST equal the current ones; `newTerms.amount` MUST equal the current amount plus the amount of `additionalInputHoldingCids`; the new terms are validated as in 3.1; and receivers introduced by the new terms must accept as in 3.2. The continuation carries the same `lockId`.

All time comparisons use ledger time. Registries SHOULD allow holdings whose lock has expired as inputs to transfers, per CIP-0112, so that `Expire` can be combined with use in one transaction.

#### 3.7 Event reporting

V2 registries MUST report every holdings change caused by these choices through `EventLog_HoldingsChange` (CIP-0112 4.3.5):

- lock creation, acceptance, and amendment: a holdings change on `terms.owner` with no transfer leg;
- enactment and expiry: for each leg to a receiver other than the owner, a holdings change on `terms.owner` and on the receiver with one `TransferLegSide` each. The `transferLegId` is prefixed by `lockId` followed by `/` and the rule id (`/fallback` for expiry), with suffixes distinguishing each enactment and each leg. The two sides of a leg MUST share an identifier; distinct legs, including those from repeated fallback enactments, MUST have distinct identifiers, as CIP-0112 requires. Legs to the owner and cancellations are holdings changes with no transfer leg.

The registry MUST issue distinct `lockId` values for distinct locks and preserve each value across continuations and amendments. A reference encoding for transfer leg identifiers is `<lockId>/<ruleId-or-fallback>/<revision>/<leg-index>`, where `revision` increases on each continuation or amendment.

For CIP-0056 transaction parsers, choice-result and holding `meta` MUST carry `splice.lfdecentralizedtrust.org/tx-kind` with a new value `lock` for creation, acceptance, and amendment; `transfer` for enactments that create receiver holdings; and the existing `unlock` for unlocks, cancellation, and expiry to the owner. Enactment results MUST carry `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`. `splice.lfdecentralizedtrust.org/reason` SHOULD be set on reject, withdraw, cancel, and expiry.

#### 3.8 Registry limits and off-ledger API

Registries implementing the package MUST advertise `splice-api-token-conditional-lock-v1` in `supportedApis` of `GET /registry/metadata/v1/instruments/{instrumentId}`, and MUST advertise their limits in the factory `meta`:

- `splice.lfdecentralizedtrust.org/conditional-lock/max-rules` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-legs` (per outcome; MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-guard-depth` (MUST be at least 3);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-duration` (ISO-8601; MUST be at least 30 days);
- `splice.lfdecentralizedtrust.org/conditional-lock/min-duration` (ISO-8601; SHOULD reflect the registry's submission delay, see Security Considerations).

Registries MUST serve:

- `POST /registry/conditional-lock/v1/lock-factory`: returns the factory contract id, choice context, and disclosed contracts for `ConditionalLockFactory_Lock`, with the same request and response shape as the CIP-0056 transfer-factory endpoint;
- `POST /registry/conditional-lock/v1/{contractId}/choice-contexts/{accept|reject|withdraw|enact|expire|cancel|amend}`: returns the choice context and disclosed contracts for the named choice.

The OpenAPI file `conditional-lock-v1.yaml` is part of the reference implementation.

### 4. Worked terms

- **HTLC leg.** One rule: enactors `[bob]`, guard `Guard_Preimage sha256 H`, outcome `Outcome_Transfer [bob: amount]`; fallback `Outcome_Unlock`.
- **Executor-free DvP across registries.** Alice locks X on registry A and Bob locks Y on registry B, each with one rule: enactors `[alice, bob]`, guard `Guard_Parties [alice, bob] 2`, outcome transfer to the counterparty. Both `Enact` choices are exercised in one Canton transaction. No executor, no hashlock, no venue.
- **Arbiter escrow.** One rule: enactors `[arbiter]`, guard `Guard_Parties [arbiter] 1`, outcome `Outcome_Distribute [buyer, seller]`; fallback `Outcome_Unlock`. The arbiter can award all to one side or split.
- **Vesting.** Four rules, each `Guard_After T_k` with `Outcome_Transfer [grantee: amount/4]`; fallback `Outcome_Unlock`. Each fires once; the lock continues with the remainder.
- **Collateral.** Rule `repaid`: enactors `[pledgee]`, guard `Guard_Parties [pledgee] 1`, outcome `Outcome_Unlock`. Rule `default`: enactors `[pledgee]`, guard `Guard_All [Guard_After maturity, Guard_Parties [pledgee] 1]`, outcome transfer all to pledgee. Margin top-up and maturity extension through `Amend`.
- **Conditional payment.** One rule: enactors `[payee]`, guard `Guard_All [Guard_Parties [attestor] 1, Guard_Before deadline]`, outcome transfer to payee; fallback `Outcome_Unlock`.

## Rationale

**A release policy rather than an HTLC.** An HTLC is one rule with one receiver and a refund. Escrow, vesting, collateral, and conditional payments are the same shape with different guards and more than one outcome. Standardizing the general form costs a small data model and one extra choice, and avoids a second CIP for each workflow.

**A closed, non-Turing guard set.** The obvious objection to a general policy is that it becomes a contract language. It does not: guards are a fixed enumeration with bounded nesting, outcomes are conservation-checked against the remaining amount, and there is no arithmetic, no state, and no reference to other contracts. Registries advertise limits, as CIP-0112 bounds transfer legs.

**Partial consumption instead of nested terms.** Firing a rule once and continuing with the remainder gives vesting and tranche release with a flat rule list. Nested successor terms would express the same thing at the cost of wallets having to render a tree.

**Conditions, not executors.** Allocations answer "who is allowed to settle these legs": a party. A conditional lock answers "what has to be true for these funds to move": a fact the ledger can check. Modeling the fact as a party reintroduces the trust the primitive exists to remove. Where a decision genuinely belongs to a party, `Guard_Parties` and `Outcome_Distribute` express it with the party's discretion bounded to a fixed receiver set.

**Atomic enactment replaces cross-lock references.** On Canton, two locks enacted in one transaction commit or fail together. That gives executor-free DvP on the same ledger without a guard that references another lock, which is why cross-lock guards are omitted.

**A new package rather than a change to `splice-api-token-holding-v2`.** Adding choices to `Holding` would break every existing implementation. A separate interface package follows the CIP-0112 evolution model: registries opt in, wallets discover support through `supportedApis`, nothing existing changes, and the on-ledger footprint is the existing `Lock` view.

**Receiver acceptance.** Creating a holding for a receiver requires the receiver's authority under the Daml model, exactly as for transfers. The instruction step mirrors `TransferInstruction` so that wallets reuse their accept flow. Swap and DvP counterparties will typically co-sign the lock in one step.

**Byte-domain hashing.** `DA.Text.sha256` hashes UTF-8 text; `DA.Crypto.Text.sha256` and `keccak256` hash the decoded bytes of a hex string. Only the latter is compatible with hashlocks on external chains, so the specification fixes the preimage format at 32 bytes of hex and the digest domain at raw bytes. Lowercasing removes hex case malleability. Both algorithms are mandatory: SHA-256 is the common denominator across Bitcoin, Lightning, and EVM HTLC implementations, and Keccak-256 is what EVM-native counterparties emit by default. Making either optional would fragment which swaps a wallet can complete against a given registry.

**Relation to CIP-0105 and CIP-0116.** Those CIPs lock Canton Coin for governance weight and staking through Amulet-specific rules with vesting schedules and beneficiary attribution. They are orthogonal: this CIP is registry-agnostic and has no governance semantics. The reference implementation for Canton Coin reuses `LockedAmulet` mechanics and does not touch DSO governance.

**Alternatives considered.**

- Application-owned escrow templates that take title to the asset: the funds leave the owner's portfolio, the wallet cannot explain them, tax and custody treatment changes, and each application repeats the work. CIP-0105's design discussion reached the same conclusion in favor of lock-as-attribute.
- Committed allocations with the counterparty as executor: releases the correct legs but requires the counterparty to be trusted to settle or cancel; no preimage semantics; fixed legs; one outcome.
- `TransferPreapproval` plus off-ledger coordination: no on-ledger enforcement of the condition or the expiry.
- Registry-specific lock contracts such as `LockedAmulet`: correct for one registry, unusable across registries, and not condition-aware.
- Cross-lock guards and oracle-data guards: unnecessary given atomic enactment and `Guard_Parties`; deferred.

## Backwards Compatibility

The CIP is additive. No existing package, interface, choice, or off-ledger endpoint changes. Registries that do not implement the package are unaffected; wallets that do not implement it still display conditionally locked holdings as locked holdings and parse their history through the existing `tx-kind` metadata (`lock` is a new value, and CIP-0056 instructs wallets to fall back to a generic rendering for unknown choices). Applications that need the primitive can test for it per instrument through `supportedApis`.

## Reference Implementation

Delivered under the accompanying Development Fund proposal and required before this CIP moves to Final:

1. The `splice-api-token-conditional-lock-v1` package with Daml Script tests covering every MUST above, including the hashlock against test vectors shared with an EVM reference contract, and every worked example in section 4.
2. `TestTokenV2` in the Splice `token-standard/examples` directory extended to implement the three interfaces, with conformance tests added to the token standard test suite.
3. A Canton Coin implementation: `LockedAmulet` extended, or a sibling template, with the corresponding `ExternalPartyAmuletRules` choices so that externally signed parties (CIP-0103) can lock, enact, and expire, and with expiry handling that respects the CIP-0107 submission delay.
4. The registry OpenAPI file and Splice wallet parsing and display of lock, enactment, expiry, cancel, and amend events.
5. An Apache-2.0 reference implementation of an atomic swap between a Canton token and an ERC-20 on an EVM test network, demonstrating the preimage flowing in both directions, and an executor-free DvP between two `TestTokenV2` instruments in one transaction.

## Security Considerations

- **Timelock ordering.** In a two-chain swap the leg that is released first by the preimage must have the shorter expiry, and the party who learns the preimage on-ledger must have enough time to claim on the other chain. The reference implementation documents the required margins.
- **Submission delay.** Registries that impose a delay between transaction preparation and execution (Canton Coin allows up to 24 hours under CIP-0107 for externally signed parties) reduce the effective enactment window. Wallets MUST account for the registry's delay when choosing `expiresAt` and `Guard_Before` times, and registries SHOULD publish `min-duration` accordingly.
- **Authoring errors.** A rule whose fixed legs exceed the remaining amount after earlier partial consumption cannot fire. Wallets SHOULD validate that every sequence of rule firings remains enactable, and registries MAY reject terms where any rule's legs exceed `amount` at creation.
- **Enactor discretion.** `Outcome_Distribute` gives the enactor discretion over amounts, bounded to the receiver set and the remaining amount. Owners SHOULD combine it with `Guard_Parties` naming the intended decision-maker.
- **Amendment.** `Amend` is unanimous among the owner and every named party, so no party's position can change without its consent. Receivers introduced by an amendment must accept.
- **Expired locks and resources.** An expired lock is enactable only through `Expire` and `Cancel`. Registries MAY enact an `Outcome_Unlock` fallback with admin authority for cleanup, analogous to `LockedAmulet_ExpireAmulet`, and MUST NOT fire any rule after expiry.
- **Preimage disclosure.** A revealed preimage is visible to the stakeholders of the enactment transaction and to anyone they disclose it to. Locks are single-use; a digest reused across locks is a wallet error, not a protocol weakness, but wallets SHOULD warn.
- **Privacy.** Digests, receivers, named parties, and lock context are visible to the lock's stakeholders and, through `Lock.context`, potentially to account providers. Wallets SHOULD keep `context` generic.
- **Authorization.** Enactment never requires the owner at enactment time; the owner's authority was granted at lock creation. Registries MUST ensure no path exists to move the locked funds other than the four choices and the expiry cleanup.

## Copyright

This CIP is licensed under CC0-1.0: [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). Code in the reference implementation is licensed under Apache-2.0.
