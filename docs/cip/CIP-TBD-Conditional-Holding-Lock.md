# CIP-TBD-Conditional-Holding-Lock

<pre>
  CIP: TBD
  Layer: Daml
  Title: Conditional Holding Lock
  Author: Chris Madison <email>cmadison@longrunadvisory.com</email>
  Status: Draft
  Type: Standards Track
  Created: 2026-09-10
  License: CC0-1.0
  Post-History: [cip-discuss thread link]
  Requires: CIP-0056, CIP-0112
</pre>

## Abstract

This CIP adds one interface package to the Canton Network Token Standard, `splice-api-token-conditional-lock-v1`, that lets the holder of a `Holding` attach a release policy to it. A conditional lock is a set of rules; each rule pairs conditions checked by the lock's signatories (a hash preimage, ledger time before or after a point, a threshold of named parties, combined as one level of alternatives over conjunctions) with an outcome: unlock to the authorizer, or release to fixed legs plus a bounded discretionary part. Rules fire at most once and may consume part of the amount, in which case the lock continues with the remainder. Every lock has an expiry, after which the remainder can only be unlocked to the authorizer. The authorizer and every named party can cancel or amend by unanimous consent.

This draft is posted to establish the need and collect use cases, not to propose that the ecosystem commit to another API set in the next release cycle. The interface specified below is a concrete strawman: it exists so that "is this expressible today, and if not what would it look like?" can be answered against something specific rather than in the abstract. Registries, wallets, and venues are asked to say on cip-discuss whether they need this primitive and which parts of it. The scope of anything shipped, and whether anything should be, follows from those answers, not from this document.

The package defines a factory, a two-step instruction for approval, the lock interface with `Enact`, `Expire`, `Cancel`, and `Amend` choices, the holding representation while locked, event reporting through the CIP-0112 `EventLog`, and the off-ledger registry endpoints wallets use to obtain factory and choice contexts. It does not modify any existing token standard package. Any registry can implement it; any V1 or V2 wallet already displays the locked holding correctly.

The primitive expresses hash time-locked atomic swaps with external chains, escrow with a decision-maker, vesting and tranche release, collateral with top-up and default, and conditional or deferred payment on an attestation, all as an attribute of the holding rather than a transfer of title.

## Motivation

The token standard describes locks but does not let anyone create one. `Holding.lock` in CIP-0056 and CIP-0112 is view data: `holders`, `expiresAt`, `expiresAfter`, `context`. There is no standard choice that locks a holding, no standard statement of who may release it, and no standard condition under which release is permitted. Canton Coin exposes a registry-specific `LockedAmulet` whose unlock requires the owner and every lock holder to act together, with a timeout for the owner. No other registry is obliged to offer anything comparable, and an application cannot write one lock flow that works across registries.

### The use cases

**HTLC legs against Bitcoin and EVM chains.** A hash time-locked contract on an external chain is only atomic if the Canton leg is released by the same preimage, checked on-ledger. *Who needs it:* market makers and bridge operators quoting a Canton instrument against BTC or an ERC-20, and the registries whose instruments they quote. Today the Canton side is either a registry-specific contract that no wallet can render, or a party who releases the funds when shown the preimage off-ledger, which is a different condition from the one the external chain checks.

**Escrow with a decision-maker.** Funds are locked by one party and awarded, in whole or in part, by a named arbiter who is neither counterparty and who is not settling a trade. *Who needs it:* marketplaces, freelance and RWA platforms, and dispute-resolution services, which today take title to the asset into an application-owned template and lose the holder's portfolio view along with it.

**Vesting and tranche release.** One lock releases a fixed fraction of the funds at each of several dates and continues with the remainder, with no party choosing an amount or a destination. *Who needs it:* token issuers paying contributors, investors, or grantees under a published schedule, and the wallets that have to show a holder what is locked and when each tranche opens.

**Collateral with top-up and default.** A pledge the pledgee releases on repayment, that the pledgee may claim after maturity, and whose amount and maturity both parties can adjust by consent without unwinding the position. *Who needs it:* lending and margin applications, and custodians who need the collateral to stay in the pledgor's account for reporting and tax treatment.

**Conditional payment on attestation.** Payment released to the payee when a named attestor acts, and only before a deadline. *Who needs it:* invoice financing, parametric insurance, and milestone payments, and any registry asked to support "pay on proof of delivery" without becoming a party to the delivery.

### What V2 already covers

CIP-0112 allocations cover more of this ground than a reading of them as venue settlement suggests, and this CIP does not propose to re-cover any of it.

**Counterparties as their own executors.** `SettlementInfo.executors` is a party list configured per settlement, not a fixed third-party role. CIP-0112 "Configurable Executors and Batch Settlement via SettlementFactory" says V2 "allows apps and assets to configure this freely" and that the field "is now a list to allow for atomicity guarantees to be distributed across multiple parties, including the V1 default set `[executor, sender, receiver]`"; CIP-0112 "Eliding Allocations for Settlement Authorizers" assumes the case "where trading parties and executors overlap". A delivery versus payment between two counterparties, with both counterparties as the executors, therefore needs no third party beyond the two registries themselves, and it works across registries, because the executors' stated job is "atomicity between settlements across different `admin` parties". Same-ledger and cross-registry DvP without a venue is a V2 feature today.

**Venue-executed matched trades.** Where a venue does match orders, CIP-0112 "Improved User Flows with Trusted Venues" covers writing the executed trade to the chain with only the executor as signatory, and "Configurable Executors and Batch Settlement via SettlementFactory" covers batching a settlement's allocations into one `SettlementFactory` choice "co-validated by the `admin` Party, [so] that party can guarantee well-authorizedness, completeness, and atomicity."

**Pre-funding.** CIP-0112 "Committed Allocations for Prefunded Trading and Iterated Settlement" covers funds committed ahead of the trade. `AllocationSpecification.committed` holds the funds until the executors settle or cancel, the deadline passes, or the admin expires the allocation, and `Allocation_Withdraw` states that for a committed allocation the choice "can only be exercised once the settlement deadline has passed."

**Executor-chosen legs and iterated settlement.** An allocation need not fix its legs in advance. With iterated settlement enabled, the executors supply `extraTransferLegSides` at settlement ("Executor settles, specifying transfer legs up to the allocated amounts"), and the settlement's result is a new allocation carrying the change, so an off-chain order book settles on-chain repeatedly against one funded position, with no custom contract code.

None of these needs a conditional lock, and this CIP is not an alternative to any of them.

### What V2 cannot express

These five are the case for the CIP. Each is stated as a capability, not as a criticism.

1. **Release conditioned on a fact the lock's signatories check, rather than on a party acting.** A preimage, or the arrival of a point in ledger time, checked by the asset's own contract at the moment of release. An allocation always releases because named parties act: `Allocation_Settle` takes an `actors` party set that implementations "MUST check … to avoid unauthorized settlement execution", and the executors are "the parties that are responsible for executing the settlement". Time in an allocation bounds *when* the parties may act, via `settlementDeadline`, and never itself releases anything. This CIP's `Guard_Preimage` and `Guard_After` are evaluated at enactment (section 3.5) and are the release condition itself. A party in `enactors` must still submit the enactment; what the guard adds is a condition the signatories check before the funds move, and an actor set that need not be the settlement executor.
2. **More than one outcome over the same locked funds.** An allocation authorizes one settlement, whose legs the executors may choose and re-choose across iterations; what it does not carry is alternative outcomes with distinct conditions attached to each. A conditional lock carries a list of rules over one pool of funds, each rule with its own guard and its own outcome, so "released to the buyer if the counterparties agree before Friday" and "apportioned by an arbiter if they do not" are two paths on one lock rather than two competing arrangements over the same balance.
3. **Discretion over amounts bounded by the terms, not by the settlement role.** Where an allocation lets a party choose amounts at release, that party is the executor set, which is also the only party that can settle at all, and the accounts it may pay are not declared anywhere in the allocation: `TransferLegSide.otherside` is supplied at settlement. A conditional lock can give the choice to a party who has no other power over the funds, gate it on a guard, and bound it to a receiver list fixed in the terms at creation and shown to the authorizer before anything is locked.
4. **Partial consumption governed by the rule that fired.** An allocation's iterated settlement returns the change to a new allocation for the same authorizer under the same executors' control, and the split is chosen by them. A conditional lock's continuation is determined by the rule: a rule whose legs sum to less than the remaining amount consumes exactly those legs, and the lock continues with the remainder and **without that rule** (section 3.6). That is what makes a four-date vesting schedule expressible as four dated rules on one lock, with no party choosing an amount or a destination and no rule able to fire twice.
5. **Amendment by unanimous consent.** CIP-0112 "Topping up Allocations" lets the executors rebalance or merge a committed allocation's funding through the standard settlement flow, and lets them reset `nextIterationFunding` at each iteration. What is not amendable is the release terms themselves and who may change them: the authorizer cannot alter the legs or the deadline of a committed allocation before that deadline, and the change of funding is made by the executors, not by the parties whose position it affects. `Amend` replaces the terms in place with the consent of the authorizer and every named party, adjusting the locked amount by additional input holdings and requiring the parties of any newly introduced receiver to act in the same amending transaction (section 3.6). Collateral top-up and maturity extension are the motivating case.

Canton can express this more cleanly than an account-model chain. A lock is an attribute of the holding, so the funds never leave the authorizer's account or portfolio view. The release paths are pre-authorized by the authorizer when the lock is created, so a receiver or an arbiter can enact a rule without the authorizer's signature at that time. Visibility is confined to the lock's stakeholders. What this CIP proposes is that the pattern be standard, so that wallets, registries, and applications interoperate on it rather than each building its own.

## Specification

### 1. Package

New Daml package `splice-api-token-conditional-lock-v1`, module `Splice.Api.Token.ConditionalLockV1`. Dependencies: `splice-api-token-metadata-v1` and `splice-api-token-holding-v2`. Build settings match the existing V2 packages (Daml-LF 2.1, explicit serializability). The package is added to the `token-standard` directory of Splice under the same license and versioning practice as the CIP-0112 packages.

### 2. Data types

```daml
module Splice.Api.Token.ConditionalLockV1 where

import DA.Map qualified as Map

import Splice.Api.Token.MetadataV1
import Splice.Api.Token.HoldingV2


-- | Hash function for a hashlock. Digests and preimages are hex-encoded byte strings.
data HashAlgorithm
  = Sha256
    -- ^ SHA-256 over the raw preimage bytes. Registries MUST support this algorithm.
  | Keccak256
    -- ^ Keccak-256 over the raw preimage bytes. Registries MUST support this algorithm.
  deriving (Eq, Ord, Show, Serializable)

-- | A condition checked by the lock contract's signatories when a rule is enacted.
-- Not recursive: a guard is always a single leaf condition.
data Guard
  = Guard_Preimage with
      algorithm : HashAlgorithm
      digest : Text
        -- ^ Digest of the 32-byte preimage under `algorithm`, as exactly 64 lowercase
        -- hexadecimal characters. Satisfied by a preimage in the witness whose digest
        -- under `algorithm` equals this value. Registries MUST reject terms whose
        -- digest is not of this form.
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
        -- MUST satisfy 1 <= threshold <= length parties. A `threshold` of 1 expresses any
        -- one of these parties.
  deriving (Eq, Ord, Show, Serializable)

-- | One way a rule can become enactable. Satisfied when every guard in `allOf` is satisfied.
data Alternative = Alternative with
    allOf : [Guard]
      -- ^ Conjunction. MUST be non-empty. Registries advertise the maximum length
      -- as `max-guards-per-alternative` (CIP section 3.8).
  deriving (Eq, Ord, Show, Serializable)

-- | Evidence supplied when enacting a rule.
data Witness = Witness with
    preimages : [Text]
      -- ^ Hex-encoded 32-byte preimages. Each `Guard_Preimage` is satisfied if any
      -- listed preimage hashes to its digest. Registries advertise the maximum
      -- length as `max-preimages`. Every choice observer of `ConditionalLock_Enact`
      -- learns every listed preimage; see `conditionalLock_enactExtraObservers`.
  deriving (Eq, Ord, Show, Serializable)

-- | A destination for locked funds.
data Leg = Leg with
    legId : Text
      -- ^ Identifies this leg in transfer events. MUST be non-empty and MUST NOT
      -- contain `/`. MUST be unique among the legs released by a single enactment,
      -- i.e. across `Outcome_Release.fixedLegs` and `ConditionalLock_Enact.legs`
      -- taken together.
    receiver : Account
      -- ^ A leg whose receiver is `terms.authorizer` returns that amount unlocked
      -- and is reported as a holdings change with no transfer leg.
    amount : Decimal
      -- ^ MUST be positive.
    meta : Metadata
      -- ^ Metadata for extensibility, reported on both `TransferLegSide`s of this
      -- leg. MUST NOT set any key the registry is required to set (CIP section 3.7).
  deriving (Eq, Ord, Show, Serializable)

-- | What happens to the locked funds when a rule fires.
data Outcome
  = Outcome_Unlock
    -- ^ The full remaining amount returns to the authorizer, unlocked. Terminates the lock.
  | Outcome_Release with
      fixedLegs : [Leg]
        -- ^ Legs fixed by the terms. Released in full whenever the rule fires.
      receivers : [Account]
        -- ^ Receiver set bounding the enactor-supplied `ConditionalLock_Enact.legs`.
        -- Every supplied leg MUST name a receiver in this list. MUST be duplicate-free.
        -- An empty list admits no enactor-supplied legs.
        --
        -- `fixedLegs` and `receivers` MUST NOT both be empty. The total released,
        -- `fixedLegs` plus the supplied legs, MUST be positive and MUST be at most
        -- the remaining amount. If it is less, the remainder stays locked and the
        -- lock continues without this rule. Registries advertise the maximum number
        -- of legs released by one enactment, `fixedLegs` plus the supplied legs, as
        -- `max-legs` (CIP section 3.8); `receivers` MUST NOT be longer than that
        -- bound.
  deriving (Eq, Ord, Show, Serializable)

-- | One release path.
data Rule = Rule with
    id : Text
      -- ^ Unique within the terms. Reported in events. MUST be non-empty and MUST NOT
      -- contain `/`; it is a component of transfer leg identifiers (CIP section 3.7).
      -- A rule id that has been enacted under a `lockId` MUST NOT be reused in later
      -- terms for that lock, including after an amendment.
    enactors : [Party]
      -- ^ Parties entitled to enact this rule. At least one MUST be among the actors.
      -- MUST be non-empty and duplicate-free.
    anyOf : [Alternative]
      -- ^ Disjunction. The rule is enactable when at least one alternative is satisfied.
      -- MUST be non-empty. A rule is a list of alternatives and an alternative is a list
      -- of guards; there is no deeper structure, so a wallet renders a rule as a
      -- two-level list of fixed shape. Registries advertise the maximum length as
      -- `max-alternatives-per-rule` (CIP section 3.8).
    outcome : Outcome
  deriving (Eq, Ord, Show, Serializable)

-- | The release policy, provided by the authorizer's wallet.
--
-- The **receivers** of terms are the accounts other than `authorizer` that appear as
-- `Leg.receiver` in any `fixedLegs` or in any `Outcome_Release.receivers`. The
-- **named parties** of terms are the parties of every receiver account, every party
-- in any `Rule.enactors`, and every party in any `Guard_Parties.parties`, excluding
-- the parties of `authorizer`. Registries advertise the maximum number of
-- named parties as `max-named-parties` (CIP section 3.8). Both terms are used
-- by the choices below and by CIP sections 3.1 to 3.4.
data LockTerms = LockTerms with
    authorizer : Account
      -- ^ Account that funds the lock and receives unlocked funds.
    instrumentId : InstrumentId
    amount : Decimal
      -- ^ Locked amount. On a continuation, the remaining amount.
    rules : [Rule]
      -- ^ Enactable strictly before `expiresAt`. Each fires at most once for the
      -- lifetime of the `lockId`; registries MUST retain the set of enacted rule ids
      -- across continuations and amendments to enforce this.
    expiresAt : Time
      -- ^ Absolute, inclusive ledger time at which the rules stop being enactable and
      -- `ConditionalLock_Expire` becomes enactable. MUST be in the future when the
      -- terms are validated, and within the registry's advertised `min-duration` and
      -- `max-duration` (CIP section 3.8).
    requestedAt : Time
      -- ^ Wallet-provided creation timestamp. MUST be in the past when locking.
    meta : Metadata
      -- ^ Metadata for extensibility. SHOULD carry
      -- `splice.lfdecentralizedtrust.org/lock-context`.
  deriving (Eq, Show, Serializable)

-- | Result of instructing, enacting, expiring, cancelling, or amending a lock.
data ConditionalLockResult = ConditionalLockResult with
    output : ConditionalLockResult_Output
    authorizerChangeCids : [ContractId Holding]
      -- ^ Change holdings created for the authorizer from the input holdings, if any.
      -- Reported here rather than in `output` so that callers can batch further
      -- actions on the change in the same Daml transaction whatever the output.
    meta : Metadata
      -- ^ Implementation-specific metadata, e.g. fees charged.
  deriving (Eq, Show, Serializable)

data ConditionalLockResult_Output
  = ConditionalLockResult_Pending with
      instructionCid : ContractId ConditionalLockInstruction
        -- ^ One or more approvals are required before the lock becomes active. Only
        -- `ConditionalLockFactory_Lock` returns this output.
  | ConditionalLockResult_Locked with
      lockCid : ContractId ConditionalLock
      holdingCids : [ContractId Holding]
        -- ^ The locked holdings backing the lock. MAY be empty for registries that do
        -- not represent their holdings on-ledger.
  | ConditionalLockResult_Enacted with
      receiverHoldingCids : [ContractId Holding]
        -- ^ Holdings created for receivers other than the authorizer.
      authorizerHoldingCids : [ContractId Holding]
        -- ^ Unlocked holdings returned to the authorizer.
      continuationCid : Optional (ContractId ConditionalLock)
        -- ^ The continuing lock, when funds remain.
  | ConditionalLockResult_Failed
      -- ^ Instruction rejected or withdrawn; input holdings unlocked.
  deriving (Eq, Show, Serializable)
```

### 3. Interfaces

#### 3.1 `ConditionalLockFactory`

```daml
-- ConditionalLockFactory
-------------------------

data ConditionalLockFactoryView = ConditionalLockFactoryView with
    admin : Party
      -- ^ Registry admin for the instruments this factory serves.
    meta : Metadata
      -- ^ MUST carry the registry's limits (CIP section 3.8).
  deriving (Eq, Show, Serializable)

interface ConditionalLockFactory where
  viewtype ConditionalLockFactoryView

  conditionalLockFactory_lockExtraObservers : ConditionalLockFactory_Lock -> [Party]
  conditionalLockFactory_lockImpl : ContractId ConditionalLockFactory -> ConditionalLockFactory_Lock -> Update ConditionalLockResult
  conditionalLockFactory_publicFetchImpl : ContractId ConditionalLockFactory -> ConditionalLockFactory_PublicFetch -> Update ConditionalLockFactoryView

  nonconsuming choice ConditionalLockFactory_Lock : ConditionalLockResult
    -- ^ Lock `terms.amount` of the authorizer's holdings under `terms`.
    with
      terms : LockTerms
        -- ^ Implementations MUST validate the terms before locking, and MUST fail
        -- otherwise: `instrumentId.admin` equals the factory `admin`; `amount` is
        -- positive; `requestedAt` is in the past; `expiresAt` is in the future and
        -- within the advertised duration bounds; every rule has non-empty,
        -- duplicate-free `enactors`, a unique non-empty `/`-free `id`, non-empty
        -- `anyOf` whose alternatives have non-empty `allOf`; every `Guard_Parties`
        -- has unique `parties` and a threshold in range; every `Guard_Preimage`
        -- digest is well-formed; every `Outcome_Release` satisfies its own
        -- constraints with `fixedLegs` summing to at most `amount`; no `Leg.meta`
        -- sets a key the registry is required to set (CIP section 3.7); and the
        -- rule, alternative, guard, leg, and named-party counts are within the
        -- advertised limits (CIP section 3.8).
      inputHoldingCids : [ContractId Holding]
        -- ^ Holdings funding the lock. Same rules as `Transfer.inputHoldingCids` in CIP-0112.
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of
        -- `terms.authorizer`. Implementations MUST check these parties to avoid
        -- unauthorized locking.
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

- The factory MUST validate `terms` as stated in the doc comment on `ConditionalLockFactory_Lock.terms` above.
- The factory MUST additionally reject terms in which any `Leg.meta` sets a key the registry is required to set (section 3.7).
- The number of named parties of the terms MUST be within the advertised `max-named-parties` (section 3.8); registries whose lock representation bounds the number of lock holders SHOULD set it to that bound.
- The **receivers** and **named parties** of the terms are as defined on `LockTerms` (section 2).
- Change holdings created from the input holdings are reported in `ConditionalLockResult.authorizerChangeCids`, whatever the output.
- If for every receiver the `actors` already include the parties the registry requires for that account, or the account holds a standing pre-approval the registry recognizes, the factory SHOULD complete in one step and return `ConditionalLockResult_Locked`.
- Otherwise the factory MUST return `ConditionalLockResult_Pending` with a `ConditionalLockInstruction`, whose `pendingApprovals` names the accounts still owed approval and whose `availableActions` reports who may give it. Input holdings SHOULD be locked to the parties the registry requires for `terms.authorizer` together with the named parties while the instruction is pending, with `expiresAt` set to `terms.expiresAt`.

#### 3.2 `ConditionalLockInstruction`

```daml
-- ConditionalLockInstruction
-----------------------------

-- | Actions to advance the state of a conditional lock instruction.
data ConditionalLockInstructionAction
  = CLIA_Accept
  | CLIA_Reject
  | CLIA_Withdraw
  | -- | Used to represent registry-specific actions that need to happen
    -- for the lock instruction to advance.
    CLIA_Custom with
      id : Text
        -- ^ Identifier of the action. Namespaced analogously to metadata keys.
  deriving (Eq, Ord, Show, Serializable)

data ConditionalLockInstructionView = ConditionalLockInstructionView with
    lockId : Text
      -- ^ Assigned by the registry when the lock is instructed and carried unchanged
      -- into `ConditionalLockView.lockId` once the lock is active, so that wallets can
      -- correlate an instruction across approvals. MUST NOT contain `/`.
    terms : LockTerms
    pendingApprovals : [Account]
      -- ^ Accounts whose approval is still required before the lock becomes active.
      -- The registry decides whether an account's owner, its provider, or both must
      -- act; see `availableActions`.
    availableActions : Map.Map ConditionalLockInstructionAction [[Party]]
      -- ^ What actions are available to which groups of parties. The list of lists
      -- is interpreted as a set of sets and represents a disjunction of
      -- conjunctions of parties, i.e., each inner list represents a group of
      -- parties that can act jointly to execute the action.
      --
      -- This field can be used to inform wallet users whether they can take an action or not;
      -- and which other parties they might be waiting on to take their action.
      --
      -- Supports multiple parties for actions that require joint authorization. Executing them
      -- will require appropriate, registry-specific delegation contracts to be in place.
    meta : Metadata
  deriving (Eq, Show, Serializable)

interface ConditionalLockInstruction where
  viewtype ConditionalLockInstructionView

  conditionalLockInstruction_acceptImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Accept -> Update ConditionalLockResult
  conditionalLockInstruction_rejectImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Reject -> Update ConditionalLockResult
  conditionalLockInstruction_withdrawImpl : ContractId ConditionalLockInstruction -> ConditionalLockInstruction_Withdraw -> Update ConditionalLockResult

  -- | Choice observers for `ConditionalLockInstruction_Accept`, so that approving
  -- the lock generates a single view. Usually the parties of `terms.authorizer`
  -- and of the accounts still in `pendingApprovals`. See CIP-0112, "Guidelines &
  -- Interfaces for Performance Optimization".
  conditionalLockInstruction_acceptExtraObservers : ConditionalLockInstruction_Accept -> [Party]
  conditionalLockInstruction_rejectExtraObservers : ConditionalLockInstruction_Reject -> [Party]
  conditionalLockInstruction_withdrawExtraObservers : ConditionalLockInstruction_Withdraw -> [Party]

  nonconsuming choice ConditionalLockInstruction_Accept : ConditionalLockResult
    -- ^ An approver accepts. The approver is the account whose approval is pending;
    -- the parties that must act for it are registry-defined and reported in
    -- `availableActions`. Result is `Locked` once every pending approval is given,
    -- otherwise `Pending`. Implementations MUST fail at or after `terms.expiresAt`;
    -- the authorizer's remedy is then `ConditionalLockInstruction_Withdraw`.
    with
      approver : Account
        -- ^ The account whose approval this exercise gives. MUST be in `pendingApprovals`.
      actors : [Party]
        -- ^ MUST be the parties the registry requires to act for `approver`, as
        -- reported in `availableActions`. Implementations MUST check these parties to
        -- avoid unauthorized acceptance.
      extraArgs : ExtraArgs
    observer conditionalLockInstruction_acceptExtraObservers this arg
    controller actors
    do conditionalLockInstruction_acceptImpl this self arg

  nonconsuming choice ConditionalLockInstruction_Reject : ConditionalLockResult
    -- ^ An approver declines. Result is `Failed`; input holdings return to the
    -- authorizer unlocked.
    with
      approver : Account
        -- ^ The account declining. MUST be in `pendingApprovals`.
      actors : [Party]
        -- ^ MUST be the parties the registry requires to act for `approver`, as
        -- reported in `availableActions`. Implementations MUST check these parties to
        -- avoid unauthorized rejection.
      extraArgs : ExtraArgs
    observer conditionalLockInstruction_rejectExtraObservers this arg
    controller actors
    do conditionalLockInstruction_rejectImpl this self arg

  nonconsuming choice ConditionalLockInstruction_Withdraw : ConditionalLockResult
    -- ^ The authorizer withdraws before every approval is given. Result is `Failed`.
    -- MUST be permitted at or after `terms.expiresAt` regardless of approver action.
    with
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of
        -- `terms.authorizer`. Implementations MUST check these parties to avoid
        -- unauthorized withdrawal. Registries MAY additionally permit the admin alone
        -- at or after `terms.expiresAt`, for resource cleanup: the funds can only
        -- return to the authorizer.
      extraArgs : ExtraArgs
    observer conditionalLockInstruction_withdrawExtraObservers this arg
    controller actors
    do conditionalLockInstruction_withdrawImpl this self arg
```

The registry assigns `lockId` when it creates the `ConditionalLockInstruction`; wallets use it to correlate an instruction across approvals, and it carries unchanged into `ConditionalLockView.lockId` once the lock becomes active (section 3.3). `ConditionalLockInstruction_Accept` MUST fail at or after `terms.expiresAt`. Registries MUST allow the authorizer to withdraw a pending instruction at or after `terms.expiresAt` regardless of approver action, so pending instructions cannot pin funds indefinitely, and MAY additionally permit the admin alone to withdraw at or after `terms.expiresAt` for cleanup, resolving to `Failed`.

#### 3.3 `ConditionalLock`

```daml
-- ConditionalLock
------------------

-- | Actions available on a conditional lock.
data ConditionalLockAction
  = CLA_Enact with
      ruleId : Text
        -- ^ The rule that can be enacted.
  | CLA_Expire
  | CLA_Cancel
  | CLA_Amend
  | -- | Used to represent registry-specific actions on conditional locks.
    CLA_Custom with
      id : Text
        -- ^ Identifier of the action. Namespaced analogously to metadata keys.
  deriving (Eq, Ord, Show, Serializable)

data ConditionalLockView = ConditionalLockView with
    lockId : Text
      -- ^ Stable across continuations and amendments. Reported in events. MUST NOT
      -- contain `/`.
    terms : LockTerms
      -- ^ Current terms: remaining amount and remaining rules.
    enactedRuleIds : [Text]
      -- ^ Ids of the rules already enacted under this `lockId`, across continuations
      -- and amendments. Wallets use it to validate a `ConditionalLock_Amend` before
      -- submitting; registries use it to enforce fire-once.
    holdingCids : [ContractId Holding]
      -- ^ The locked holdings backing this lock. MAY be empty for registries that do
      -- not represent their holdings on-ledger.
    availableActions : Map.Map ConditionalLockAction [[Party]]
      -- ^ What actions are available to which groups of parties. The list of lists
      -- is interpreted as a set of sets and represents a disjunction of
      -- conjunctions of parties, i.e., each inner list represents a group of
      -- parties that can act jointly to execute the action.
      --
      -- This field can be used to inform wallet users whether they can take an action or not;
      -- and which other parties they might be waiting on to take their action.
      --
      -- Supports multiple parties for actions that require joint authorization. Executing them
      -- will require appropriate, registry-specific delegation contracts to be in place.
      --
      -- `CLA_Enact` has one entry per rule in `terms.rules`. Presence means the rule
      -- exists and the listed groups are entitled to enact it, not that any of its
      -- alternatives is currently satisfied; wallets evaluate `anyOf` themselves
      -- against ledger time and the witness they hold.
    meta : Metadata
  deriving (Eq, Show, Serializable)

interface ConditionalLock where
  viewtype ConditionalLockView

  conditionalLock_enactImpl : ContractId ConditionalLock -> ConditionalLock_Enact -> Update ConditionalLockResult
  conditionalLock_expireImpl : ContractId ConditionalLock -> ConditionalLock_Expire -> Update ConditionalLockResult
  conditionalLock_cancelImpl : ContractId ConditionalLock -> ConditionalLock_Cancel -> Update ConditionalLockResult
  conditionalLock_amendImpl : ContractId ConditionalLock -> ConditionalLock_Amend -> Update ConditionalLockResult

  -- | Choice observers for `ConditionalLock_Enact`, so that enacting a rule
  -- generates a single view. `ConditionalLock_Enact`'s arguments include
  -- `witness.preimages`, so every choice observer learns every revealed preimage.
  -- Implementations MUST NOT return parties beyond those of the accounts the enacted
  -- outcome pays unless the instrument is public: none for `Outcome_Unlock`, the
  -- parties of the receiver accounts of the released legs for `Outcome_Release`.
  --
  -- This function is evaluated before the choice body. It MUST be total and MUST
  -- NOT fail. In particular, a `ruleId` that is not in `terms.rules`, because it is
  -- unknown or already fired, MUST yield the empty list and let the body reject the
  -- exercise.
  conditionalLock_enactExtraObservers : ConditionalLock_Enact -> [Party]

  -- | Choice observers for `ConditionalLock_Expire`. None, as for `Outcome_Unlock`
  -- under `ConditionalLock_Enact`.
  conditionalLock_expireExtraObservers : ConditionalLock_Expire -> [Party]

  -- | Choice observers for `ConditionalLock_Cancel`. Usually the named parties of
  -- the current terms, whose consent the choice already requires.
  conditionalLock_cancelExtraObservers : ConditionalLock_Cancel -> [Party]

  -- | Choice observers for `ConditionalLock_Amend`. Usually the named parties of
  -- the current terms together with those introduced by `newTerms`.
  conditionalLock_amendExtraObservers : ConditionalLock_Amend -> [Party]

  nonconsuming choice ConditionalLock_Enact : ConditionalLockResult
    -- ^ Fire one rule. Implementations MUST fail if ledger time is at or after
    -- `terms.expiresAt`; if no party in the rule's `enactors` is among `actors`; if
    -- no alternative in the rule's `anyOf` is satisfied (CIP section 3.5); or if
    -- `legs` are not valid for the outcome (CIP section 3.6).
    with
      ruleId : Text
      actors : [Party]
        -- ^ MUST include at least one of the rule's `enactors`.
        -- Implementations MUST check these parties to avoid unauthorized enactment.
      witness : Witness
      legs : [Leg]
        -- ^ Enactor-supplied legs. MUST be empty unless the rule's outcome is an
        -- `Outcome_Release` with a non-empty `receivers`, and each supplied leg's
        -- receiver MUST then be in that list. The number of supplied legs plus
        -- `fixedLegs` MUST be within the advertised `max-legs`.
      extraArgs : ExtraArgs
    observer conditionalLock_enactExtraObservers this arg
    controller actors
    do conditionalLock_enactImpl this self arg

  nonconsuming choice ConditionalLock_Expire : ConditionalLockResult
    -- ^ Return the full remaining amount to `terms.authorizer`, unlocked, and
    -- terminate the lock. MUST fail before `terms.expiresAt`. No continuation is
    -- created.
    with
      actors : [Party]
        -- ^ MUST include either the parties the registry requires to unlock funds in
        -- the authorizer account or, where the registry permits admin-only cleanup,
        -- the admin alone; the funds can only return to the authorizer in either
        -- case. Implementations MUST check these parties to avoid unauthorized
        -- expiry.
      extraArgs : ExtraArgs
    observer conditionalLock_expireExtraObservers this arg
    controller actors
    do conditionalLock_expireImpl this self arg

  nonconsuming choice ConditionalLock_Cancel : ConditionalLockResult
    -- ^ Return the full remaining amount to the authorizer unlocked, including after expiry, with the
    -- consent of every named party.
    with
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of
        -- `terms.authorizer` and every named party of the current terms.
        -- Implementations MUST check these parties to avoid unauthorized
        -- cancellation.
      extraArgs : ExtraArgs
    observer conditionalLock_cancelExtraObservers this arg
    controller actors
    do conditionalLock_cancelImpl this self arg

  nonconsuming choice ConditionalLock_Amend : ConditionalLockResult
    -- ^ Replace the terms, optionally adding funds, with the consent of every named
    -- party of the current terms and the authorizer. Result is `Locked` with the new
    -- lock, which retains `lockId`. Implementations MUST fail at or after the
    -- current `terms.expiresAt`.
    --
    -- An amendment MUST NOT return `Pending`: every approval that `newTerms`
    -- introduces MUST be given in the amending transaction, so `actors` MUST also
    -- include the parties the registry requires for each receiver account that
    -- `newTerms` introduces. This keeps the pre-amendment rules enforceable at all
    -- times and gives no party a path to unwind a live lock.
    with
      newTerms : LockTerms
        -- ^ `authorizer` and `instrumentId` MUST equal the current ones. `amount`
        -- MUST equal the current `terms.amount` plus the amount of
        -- `additionalInputHoldingCids`; an amendment MUST NOT reduce the locked
        -- amount, and a registry that charges a fee for the amendment MUST take it
        -- from the additional inputs or from change and report it in
        -- `ConditionalLockResult.meta`. `expiresAt` MAY move in either direction
        -- subject to the same bounds as at creation. `rules` MAY be added, removed,
        -- or replaced, but MUST NOT reuse an id in `enactedRuleIds`. Otherwise
        -- validated as `ConditionalLockFactory_Lock.terms`.
      additionalInputHoldingCids : [ContractId Holding]
        -- ^ Holdings topping up the lock. Same rules as
        -- `ConditionalLockFactory_Lock.inputHoldingCids`. MAY be empty, for an
        -- amendment that changes only the terms.
      actors : [Party]
        -- ^ MUST include the parties the registry requires to move funds out of
        -- `terms.authorizer` and every named party of the current terms and the
        -- parties required for every receiver account `newTerms` introduces.
        -- Implementations MUST check these parties to avoid unauthorized amendment.
      extraArgs : ExtraArgs
    observer conditionalLock_amendExtraObservers this arg
    controller actors
    do conditionalLock_amendImpl this self arg
```

The choices are nonconsuming, following CIP-0112, so that implementations control consumption. On success, implementations MUST archive the `ConditionalLock` and the backing holdings in the same transaction, creating a continuation lock and holdings when funds remain.

The signatories of a `ConditionalLock` MUST include the registry admin, the parties the registry requires to move funds out of `terms.authorizer`, and the parties of every receiver account that has approved; guards are therefore checked by those parties when a rule is enacted, and the enactor supplies the `witness` without being trusted to evaluate it.

`ConditionalLockView.enactedRuleIds` is the registry's record of fire-once across continuations and amendments.

#### 3.4 Holding representation while locked

A registry that represents holdings on-ledger MUST, while a lock is active, represent the funds as the `Holding`s referenced by `holdingCids`, in `terms.authorizer`, with amounts summing to `terms.amount` and `lock` set on each to:

- `holders`: the named parties of the terms (`LockTerms`, section 2); if the terms name no party other than the authorizer, `holders` is the registry admin alone;
- `expiresAt = Some terms.expiresAt`;
- `expiresAfter = None`;
- `context`: a short human-readable description, for example `hashlock to <receiver>`, `escrow, arbiter <party>`, or `vesting, 4 tranches`.

The holding's `meta` MUST carry `splice.lfdecentralizedtrust.org/lock-context` with the same text. The `ConditionalLock` interface MAY be implemented by the same contract as the `Holding`, as `LockedAmulet` does, or by a separate contract referencing it.

This is what makes the CIP invisible to existing wallets: a conditionally locked holding is a locked holding, and CIP-0056 and CIP-0112 wallets already render those. A registry that does not represent holdings on-ledger, as CIP-0112 permits, reports the same lock information through whatever holdings view it offers, and `holdingCids` is empty.

#### 3.5 Guard evaluation

A rule is enactable when at least one alternative in `anyOf` is satisfied. An alternative is satisfied when every guard in its `allOf` is satisfied. Guards are evaluated at enactment against ledger time, the `witness`, and the `actors`:

- `Guard_Preimage`: satisfied if some entry of `witness.preimages`, lowercased, is exactly 32 bytes of hex and its digest under `algorithm`, computed with `DA.Crypto.Text.sha256` or `DA.Crypto.Text.keccak256`, equals `digest`. The digest is computed over the decoded bytes, not over the hex text, so the same preimage satisfies an EVM `sha256(bytes32)` or a Bitcoin `OP_SHA256` lock.
- `Guard_After`: satisfied if ledger time is at or after `time`.
- `Guard_Before`: satisfied if ledger time is strictly before `time`.
- `Guard_Parties`: satisfied if at least `threshold` distinct members of `parties` are among `actors`.

Registries MUST support all guard kinds, MUST support at least eight alternatives per rule and eight guards per alternative, and MUST advertise the values they support (section 3.8). Guards are a closed set with no deeper structure: there is no arithmetic, no reference to other contracts, no repetition, and no nesting beyond the fixed two levels of `anyOf` and `allOf`.

`ConditionalLockView.availableActions` entries for `CLA_Enact` mean that the listed groups are entitled to enact the rule, not that any of its alternatives is currently satisfied: wallets evaluate `anyOf` themselves against ledger time and the witness they hold.

#### 3.6 Outcome enactment and continuation

On `Enact` of rule `r` with remaining amount `a`:

- `Outcome_Unlock`: `a` returns to the authorizer unlocked; the lock terminates.
- `Outcome_Release`: `fixedLegs` are released in full whenever the rule fires; the enactor-supplied `legs` MUST each name a receiver in `receivers` and MUST be empty when `receivers` is empty. The total released, `fixedLegs` plus the supplied `legs`, MUST be positive and at most `a`. If it is less, the lock continues with amount `a` minus the total released and rules `terms.rules` minus `r`. Otherwise it terminates. A leg whose receiver is `terms.authorizer` returns that amount unlocked rather than transferring it.

`Expire` returns the full remaining amount to the authorizer, unlocked, and terminates the lock. It never creates a continuation. `Expire`'s actors are either the parties the registry requires to unlock funds in the authorizer account or, where the registry permits admin-only cleanup, the admin alone; the funds can only return to the authorizer in either case. Registries MUST NOT fail an `Expire` for reasons attributable to any party other than the authorizer.

Creation of receiver holdings is a transfer: registry rules that apply to transfers into the receiver account (allow lists, pause status, account provider controls) apply to enactment. Registries MAY fail an enactment for those reasons.

Conservation is checked against the terms: registries whose holdings carry fees MAY deliver reduced amounts and MUST report the deduction in the result `meta`.

`Cancel` requires the parties the registry requires to move funds out of the authorizer account plus every named party of the current terms.

`Amend` replaces the terms of an active lock in one transaction, optionally adding funds, and never returns `Pending`. It requires the parties the registry requires to move funds out of the authorizer account plus every named party of the current terms. In addition:

- `newTerms.authorizer` and `newTerms.instrumentId` MUST equal the current ones. The instrument fixes the admin, which is a stakeholder of the lock; changing it would be a new lock at a different registry, not an amendment.
- `newTerms.amount` MUST equal the current `terms.amount` plus the amount of `additionalInputHoldingCids`, which follow the same rules as `ConditionalLockFactory_Lock.inputHoldingCids` and MAY be empty. Checking against `terms.amount`, a stated quantity, rather than the holding's current balance means holding-fee decay does not break the equality. `Amend` MUST NOT reduce the locked amount: partial release is `Enact`, and full release is `Cancel`. A registry that charges a fee for the amendment MUST take it from the additional inputs or from change and report it in `ConditionalLockResult.meta`.
- `newTerms` is validated as in section 3.1, including that `newTerms.expiresAt` is in the future and within the registry's advertised `min-duration` and `max-duration`.
- `newTerms.expiresAt` MAY move earlier or later than the current `expiresAt`, within those same creation bounds. Because the amendment is unanimous among the authorizer and every named party of the current terms, every party whose position a change of expiry affects has consented to it.
- `newTerms.rules` MAY add, remove, or replace rules, but MUST NOT reuse an id in `enactedRuleIds` (section 3.3). Reusing the id of a rule that has not fired is permitted.
- `newTerms.requestedAt` MUST be in the past and SHOULD be the wallet's timestamp for the amendment rather than the original lock.
- Receivers of the current terms are named parties and therefore authorize the amendment as part of the unanimity requirement. Every approval that `newTerms` introduces for a newly introduced receiver account is given in the amending transaction: `actors` MUST include the parties the registry requires for that account.
- `Amend` MUST fail at or after the current `terms.expiresAt`.
- On success the lock and its backing holdings are archived and a continuation lock and backing holdings are created, as for every other choice in section 3.3. The continuation carries the same `lockId` and retains the set of enacted rule ids.

All time comparisons use ledger time. Registries SHOULD allow holdings whose lock has expired as inputs to transfers, per the `Holding.lock` doc comment in `splice-api-token-holding-v2`, so that `Expire` can be combined with use in one transaction.

#### 3.7 Event reporting

V2 registries MUST report every holdings change caused by these choices through `EventLog_HoldingsChange` (CIP-0112 "EventLog for Transaction Parsing"):

- lock creation, approval, and amendment: a holdings change on `terms.authorizer` with no transfer leg;
- enactment: for each leg whose receiver is not `terms.authorizer`, a holdings change on `terms.authorizer` and one on the receiver, each carrying one `TransferLegSide` for that leg. Both sides share the identifier `<lockId>/<ruleId>/<legId>`; the leg's `meta` is carried on both sides. A leg whose receiver is `terms.authorizer` is a holdings change with no transfer leg, as for expiry and cancellation below;
- expiry and cancellation: a holdings change on `terms.authorizer` with no transfer leg.

The two sides of a leg MUST share an identifier; distinct legs, including those of different enactments, MUST have distinct identifiers, as CIP-0112 requires. `lockId`, `Rule.id`, and `Leg.legId` MUST be non-empty and MUST NOT contain `/`. The registry issues `lockId` when the lock is instructed (section 3.2); it MUST be distinct per lock and MUST remain stable across approvals, continuations, and amendments. The encoding for transfer leg identifiers is `<lockId>/<ruleId>/<legId>`: a rule id is enacted at most once for the lifetime of a `lockId`, and leg ids are unique within an enactment, so the three components are already unique.

`TransferLegSide.meta` MUST contain every key of the corresponding `Leg.meta`. `Leg.meta` MUST NOT set `splice.lfdecentralizedtrust.org/tx-kind`, `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`, or any other key under `splice.lfdecentralizedtrust.org/conditional-lock/` that the registry is required to set; registries MUST reject terms in which any `Leg.meta` sets one of these keys, at creation and at amendment. `splice.lfdecentralizedtrust.org/reason` on a leg is not reserved, and is the wallet-visible way to label an individual leg, for example a tranche number or an arbiter's fee.

For CIP-0056 transaction parsers, choice-result and holding `meta` MUST carry `splice.lfdecentralizedtrust.org/tx-kind` with a new value `lock` for creation, approval, and amendment; `transfer` for enactments that create receiver holdings; and the existing `unlock` for unlock outcomes, cancellation, and expiry. Enactment results MUST carry `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`. `splice.lfdecentralizedtrust.org/reason` SHOULD be set on reject, withdraw, cancel, expire, and amend.

#### 3.8 Registry limits and off-ledger API

Registries implementing the package MUST advertise `splice-api-token-conditional-lock-v1` in `supportedApis` of `GET /registry/metadata/v1/instruments/{instrumentId}`, and MUST advertise their limits in the factory `meta`:

- `splice.lfdecentralizedtrust.org/conditional-lock/max-rules` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-legs` (the maximum number of legs released by one enactment, i.e. `length fixedLegs + length ConditionalLock_Enact.legs`; MUST be at least 8; the same bound applies to `Outcome_Release.receivers`);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-alternatives-per-rule` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-guards-per-alternative` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-preimages` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-named-parties` (the maximum number of distinct named parties of the terms, which is the number of parties the registry must carry as lock holders; MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-duration` (ISO-8601; MUST be at least 30 days);
- `splice.lfdecentralizedtrust.org/conditional-lock/min-duration` (ISO-8601; SHOULD reflect the registry's submission delay, see Security Considerations; for Canton Coin at least 24 hours per CIP-0107).

Registries MUST serve:

- `POST /registry/conditional-lock/v1/lock-factory`: returns the factory contract id, choice context, and disclosed contracts for `ConditionalLockFactory_Lock`, with the same request and response shape as the CIP-0056 transfer-factory endpoint;
- `POST /registry/conditional-lock/v1/{lockInstructionId}/choice-contexts/{accept|reject|withdraw}`: returns the choice context and disclosed contracts for the named choice on a `ConditionalLockInstruction`;
- `POST /registry/conditional-lock/v1/{lockId}/choice-contexts/{enact|expire|cancel|amend}`: returns the choice context and disclosed contracts for the named choice on a `ConditionalLock`.

The OpenAPI file `conditional-lock-v1.yaml` is part of the reference implementation.

#### 3.9 View budget

Canton's transaction cost is driven by the number of views a transaction generates, and a view is created whenever a called choice has informees the calling choice does not (CIP-0112, "Guidelines & Interfaces for Performance Optimization"). Registries MUST implement `conditionalLockFactory_lockExtraObservers`, `conditionalLockInstruction_acceptExtraObservers`, `conditionalLockInstruction_rejectExtraObservers`, `conditionalLockInstruction_withdrawExtraObservers`, `conditionalLock_enactExtraObservers`, `conditionalLock_expireExtraObservers`, `conditionalLock_cancelExtraObservers`, and `conditionalLock_amendExtraObservers` to set the choice observers of the corresponding choices. They SHOULD do so so that each choice generates a single view.

Usually this means:

- `ConditionalLockFactory_Lock`: the parties of `terms.authorizer` and of every account whose approval the registry expects in the same transaction.
- `ConditionalLockInstruction_Accept`, `_Reject`, `_Withdraw`: the parties of `terms.authorizer` and of the accounts still in `pendingApprovals`.
- `ConditionalLock_Enact`: the parties of the accounts the enacted outcome pays: none for `Outcome_Unlock`, the parties of the `fixedLegs` receiver accounts and of the enactor-supplied `legs` receiver accounts for `Outcome_Release`.
- `ConditionalLock_Expire`: none; the funds return to the authorizer, who is already a signatory, as for `Outcome_Unlock` under `ConditionalLock_Enact`.
- `ConditionalLock_Cancel` and `ConditionalLock_Amend`: the named parties whose consent the choice already requires, and for `Amend` also the named parties introduced by `newTerms`.

An `ExtraObservers` function is evaluated before the choice body. It MUST be total and MUST NOT fail. In particular, `ConditionalLock_Enact` with a `ruleId` that is not in `terms.rules` MUST yield the empty list and leave the rejection to the choice body.

Registries whose instruments do not require confidentiality between a lock's stakeholders MAY set all named parties of the terms as choice observers on every choice, so that the set of informees only decreases as the transaction tree is walked, as CIP-0112 recommends for such assets. Registries that do require confidentiality between them MUST NOT: in particular, a `Guard_Preimage` enactment reveals the preimage to every informee of the exercise, so `conditionalLock_enactExtraObservers` MUST NOT name parties beyond the accounts the outcome pays unless the registry's instrument is public, because the choice arguments carry the revealed preimages.

The intended budget is one view per exercised choice. The escrowed DvP with a dispute window of section 4 exercises two `ConditionalLock_Enact` choices, one per registry, in a single transaction when `settle` fires; it SHOULD therefore cost at most three views: the root and one per registry.

These functions bound visibility, not authorization: a choice observer is not an actor, and naming a party here never entitles it to enact a rule.

### 4. Worked terms

Written in shorthand: accounts are shown as their owning party, and `Leg` is shown without its `meta`, which is empty in every example.

- **HTLC leg.** One rule: enactors `[bob]`, one alternative `allOf [Guard_Preimage Sha256 H]`, outcome `Outcome_Release with fixedLegs = [Leg "claim" bob amount]; receivers = []`.
- **Escrowed DvP with a dispute window.** Alice locks X for Bob with `deadline < expiresAt` and two rules. Rule `settle`: enactors `[alice, bob]`, one alternative `allOf [Guard_Parties [alice, bob] 2, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "delivery" bob amount]; receivers = []`, the whole amount, so the lock terminates. Rule `award`: enactors `[arbiter]`, one alternative `allOf [Guard_After deadline, Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [alice, bob]`. Bob's lock of Y on registry B is symmetric, and the two `settle` enactments are exercised in one Canton transaction. The two rules are mutually exclusive in time: `settle` only strictly before the deadline, `award` only from the deadline until expiry, and after expiry only `Expire`, which returns the remainder to Alice. A partial award consumes the `award` rule, so the arbiter decides once. One pool of funds, two conditions, two outcomes.
- **Arbiter escrow.** One rule: enactors `[arbiter]`, one alternative `allOf [Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [buyer, seller]`. The arbiter can award all to one side or split.
- **Vesting.** Four rules, each with enactors `[grantee]`, one alternative `allOf [Guard_After T_k]`, and outcome `Outcome_Release with fixedLegs = [Leg "tranche-k" grantee (amount/4)]; receivers = []`. Each fires once; the lock continues with the remainder. No party chooses an amount or a destination; the grantee only submits the enactment once the date has passed.
- **Collateral.** Rule `repaid`: enactors `[pledgee]`, one alternative `allOf [Guard_Parties [pledgee] 1]`, outcome `Outcome_Unlock`. Rule `default`, with `maturity < expiresAt` so that it is enactable between maturity and expiry: enactors `[pledgee]`, one alternative `allOf [Guard_After maturity, Guard_Parties [pledgee] 1]`, outcome `Outcome_Release with fixedLegs = [Leg "default" pledgee amount]; receivers = []`. Margin top-up and maturity extension through `Amend`, reusing the `default` rule's id, which is legal because it has not fired and so is not in `enactedRuleIds`.
- **Conditional payment.** One rule, with `deadline <= expiresAt`: enactors `[payee]`, one alternative `allOf [Guard_Parties [attestor] 1, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "payment" payee amount]; receivers = []`.

## Rationale

**A release policy rather than an HTLC.** An HTLC is one rule with one receiver and a refund. Escrow, vesting, collateral, and conditional payments are the same shape with different guards and more than one outcome. Standardizing the general form costs a small data model and one extra choice, and avoids a second CIP for each workflow.

**A closed, non-Turing guard set.** The obvious objection to a general policy is that it becomes a contract language. It does not: a rule is a disjunction of alternatives and an alternative is a conjunction of guards, with no deeper structure, outcomes are conservation-checked against the remaining amount, and there is no arithmetic, no state, and no reference to other contracts. Registries advertise limits, as CIP-0112 bounds transfer legs.

**Partial consumption instead of nested terms.** Firing a rule once and continuing with the remainder gives vesting and tranche release with a flat rule list. Nested successor terms would express the same thing at the cost of wallets having to render a tree.

**A fixed two-level guard shape.** The guard shape applies the same principle to conditions: `anyOf` is a disjunction of alternatives and each alternative's `allOf` is a conjunction of guards, with no deeper structure, so a wallet renders a rule as a two-level list of fixed shape rather than writing a recursive renderer with its own depth budget.

**Conditions as well as executors.** Counterparties as their own executors is the right answer for delivery versus payment, and this CIP does not compete with it: CIP-0112 makes the executor set a configurable party list and explicitly contemplates the trading parties filling it, which settles DvP (same ledger or across registries, with a venue or without one) inside the allocation model. What an allocation does not answer is "what has to be true for these funds to move" when the answer is not a party: a preimage, or a point in ledger time. Where the decision does belong to a party, `Guard_Parties` names that party and the release outcome bounds its discretion to a receiver set fixed in the terms, which is a different thing from being the party who settles.

**Atomicity instead of cross-lock guards.** Two locks enacted in one Canton transaction commit or fail together, so a guard that refers to the state of another lock would add nothing; cross-lock guards are omitted for that reason. This is a property of Daml transactions rather than of this interface. Allocations rely on the same property, and CIP-0112 assigns responsibility for it to the settlement's executors and to each asset's admin.

**Expiry always unlocks.** Every case for a directed outcome on expiry (pay the pledgee at maturity, pay the payee if nobody objects, sweep to a treasury account) is better written as an ordinary rule: a `Guard_After` condition with `enactors` naming the beneficiary, and `expiresAt` set after the guard as the safety valve. Neither form is automatic; something must submit a transaction either way, so a special expiry outcome buys nothing a rule does not, and it is worse on two counts. It names the wrong actor, since `Expire` is enactable by the authorizer, the party giving funds away, rather than by the beneficiary a rule's `enactors` can name; and it removes the safety valve, since an outcome nobody enacts leaves funds stranded with no later expiry behind it, where a rule's own `expiresAt` still brings them home. This also matches CIP-0112, where expiry, withdrawal, and cancellation only ever release an allocation's funds to its authorizer; directed movement is `Allocation_Settle`, and it stops being available once the deadline passes.

**One release outcome.** A fixed-legs outcome and a discretionary outcome cannot together express a fixed fee plus a discretionary remainder: forcing the fee into the discretionary receiver set gives the party who chooses amounts the power to pay itself the whole balance, which is exactly the unbounded discretion this CIP's Security Considerations warns against. Decomposing the fee into one rule and the discretionary award into another is not atomic (the arbiter can take the fee and never award, or award the remainder first and strand the fee) and it spends two rule slots on one economic action. `Outcome_Release` merges the two: `receivers = []` is the pure fixed case, `fixedLegs = []` is the pure discretionary case, and both non-empty is the case that was missing, checked by a single conservation rule over `fixedLegs` plus the enactor-supplied legs. This is also the shape CIP-0112 allocations already use (legs fixed at authorization and legs supplied at execution, validated together against one budget) rather than a construct invented for this CIP.

**A new package rather than a change to `splice-api-token-holding-v2`.** Adding choices to `Holding` would break every existing implementation. A separate interface package follows the CIP-0112 evolution model: registries opt in, wallets discover support through `supportedApis`, nothing existing changes, and the on-ledger footprint is the existing `Lock` view.

**What a registry must implement.** The package requires three interfaces and the holding representation of section 3.4, which is the existing `Lock` view CIP-0056 already defines. Guard and outcome evaluation is pure, a function of the terms, the witness, the actors, and ledger time, so it can be shared as a library rather than reimplemented per registry. The reference evaluator imports only the Splice API packages and the standard library. The off-ledger surface is two endpoint shapes copied from the transfer factory: the factory endpoint and the choice-context endpoint of section 3.8. Every registry that already implements CIP-0112 can implement this package at the same Daml-LF target. An optional API that registries implement in parts would be worth less than no API at all, which is why every guard kind and every outcome is mandatory for any registry that advertises `splice-api-token-conditional-lock-v1`, with only the numeric limits of section 3.8 left to the registry.

**Approvals.** Creating a holding for a receiver requires the receiver's authority under the Daml model, exactly as for transfers, and registries MAY require an account's provider to authorize alongside its owner (`HoldingV2` leaves that split to the implementation). The instruction step therefore names accounts whose approval is outstanding rather than receivers specifically, and reports which parties may act through `availableActions`, so that wallets reuse their `TransferInstruction` accept flow unchanged. Swap and DvP counterparties will typically co-sign the lock in one step.

**Byte-domain hashing.** `DA.Text.sha256` hashes UTF-8 text; `DA.Crypto.Text.sha256` and `keccak256` hash the decoded bytes of a hex string. Only the latter is compatible with hashlocks on external chains, so the specification fixes the preimage format at 32 bytes of hex and the digest domain at raw bytes. Lowercasing removes hex case malleability. Both algorithms are mandatory: SHA-256 is the common denominator across Bitcoin, Lightning, and EVM HTLC implementations, and Keccak-256 is what EVM-native counterparties emit by default. Making either optional would fragment which swaps a wallet can complete against a given registry.

**Relation to CIP-0105 and CIP-0116.** Those CIPs require Canton Coin to be locked per PartyId as a condition of Super Validator weight and Featured App eligibility, with vesting-based unlock schedules. They are orthogonal: this CIP is registry-agnostic and has no governance semantics. A Canton Coin implementation would reuse `LockedAmulet` mechanics and would not touch DSO governance.

**Alternatives considered.**

- Application-owned escrow templates that take title to the asset: the funds leave the authorizer's portfolio, the wallet cannot explain them, tax and custody treatment changes, and each application repeats the work. CIP-0105 requires locking to work from self-custody wallets, institutional custodians, and third-party custody providers alike, which an application-owned template cannot offer.
- Committed allocations with the counterparty as executor: the right tool for a trade whose legs are known or chosen at settlement, including pre-funded and venue-matched ones, and the reason this CIP claims no DvP use case for itself. What it does not give is a release condition the lock's signatories check, more than one outcome over the same funds, or a choice of amounts bounded by a receiver set fixed in the terms.
- `TransferPreapproval` plus off-ledger coordination: no on-ledger enforcement of the condition or the expiry.
- Registry-specific lock contracts such as `LockedAmulet`: correct for one registry, unusable across registries, and not condition-aware.
- Cross-lock guards and oracle-data guards: unnecessary given atomic enactment and `Guard_Parties`; deferred.

## Backwards Compatibility

The CIP is additive. No existing package, interface, choice, or off-ledger endpoint changes. Registries that do not implement the package are unaffected; wallets that do not implement it still display conditionally locked holdings as locked holdings and fall back to the generic rendering CIP-0056 prescribes for choices outside the standard (`lock` is a new `tx-kind` value). Applications that need the primitive can test for it per instrument through `supportedApis`.

## Reference Implementation

An Apache-2.0 reference implementation exists today, out of tree. At the time of this revision it implements the round-one shape of the interface and is being updated to the interface specified here; the repository tracks this document. It can be taken as a dependency by any registry or application that wants to try the primitive before it is part of Splice:

1. The `splice-api-token-conditional-lock-v1` package, with Daml Script tests covering the interface's MUSTs, hashlock test vectors shared with an EVM reference contract, and a named script for each worked example in section 4.
2. An implementation over the published `TestTokenV2` package, showing that a V2 registry can support the interface with no change to any existing token standard package, and that support is discoverable per instrument through `supportedApis`.
3. The registry OpenAPI file `conditional-lock-v1.yaml`.
4. Executable proofs of the properties the interface claims: byte-domain hashing against SHA-256 and Keccak-256 vectors shared with EVM and Solana reference programs, receiver authorization that persists to enactment time, one-step locking, and two locks on two registries settling atomically in one transaction.

What is not done, and what this CIP does not schedule, is the work that belongs to the Splice maintainers:

- adding the package to the `token-standard` directory;
- extending `TestTokenV2` in the Splice tree with conformance tests in the token standard suite;
- wallet parsing and display of the lock, enactment, expiry, cancel, and amend events;
- a Canton Coin implementation:
  - a sibling template embedding the same `TimeLock` representation `LockedAmulet` uses so existing wallets render it unchanged;
  - a `ConditionalLockFactory` instance on `ExternalPartyAmuletRules` so externally signed parties (CIP-0103) can lock, enact, and expire within the CIP-0107 submission delay;
  - the Amulet holding fee handled by viewing the initial amount, as `LockedAmulet` already does, and netting the accrued fee out of the enacted legs;
  - a DSO cleanup path for expired locks analogous to `LockedAmulet_ExpireAmulet`;
  - a `min-duration` of at least 24 hours.

Those follow if and when the maintainers schedule them, and they are the work required before this CIP could move to Final.

An end-to-end atomic swap against an ERC-20 on an EVM test network, showing the preimage flowing in both directions, is not built; the shared hash vectors establish the byte-domain compatibility such a swap depends on.

## Security Considerations

- **Timelock ordering.** In a two-chain swap the leg that is released first by the preimage must have the shorter expiry, and the party who learns the preimage on-ledger must have enough time to claim on the other chain. The reference implementation documents the required margins.
- **Blocked receivers.** Enactment creates a holding for the receiver, so the registry rules that apply to transfers into that account apply to it (section 3.6). If the receiver's account is paused or off an allow list at enactment time, the rule cannot fire and the remainder returns to the authorizer at expiry. In a two-chain swap this loses the Canton leg while leaving the external leg claimable, so counterparties SHOULD confirm receiver account status before funding the external leg, and registries SHOULD surface account status through the choice-context endpoint of section 3.8.
- **Submission delay.** Registries that impose a delay between transaction preparation and execution (Canton Coin allows up to 24 hours under CIP-0107 for externally signed parties) reduce the effective enactment window. Wallets MUST account for the registry's delay when choosing `expiresAt` and `Guard_Before` times, and registries SHOULD publish `min-duration` accordingly.
- **Authoring errors.** A rule whose `fixedLegs` exceed the remaining amount after earlier partial consumption cannot fire. Wallets SHOULD validate that every sequence of rule firings remains enactable, and registries MAY reject terms where any rule's legs exceed `amount` at creation.
- **Enactor discretion.** `Outcome_Release` with a non-empty `receivers` gives the enactor discretion over amounts, bounded to the receiver set and to the remaining amount net of `fixedLegs`. Authorizers SHOULD combine it with `Guard_Parties` naming the intended decision-maker.
- **Preimage evaluation.** A preimage in `witness.preimages` is hashed and compared under the authority of the lock's signatories (section 3.3) when `Enact` is exercised. The enactor supplies the witness but is not trusted to evaluate it: a lying enactor cannot make a guard appear satisfied when it is not.
- **Amendment.** `Amend` is unanimous among the authorizer and every named party, so no party's position can change without its consent, and it never returns `Pending`: every approval that `newTerms` introduces is given in the amending transaction. A rule that has fired cannot be reinstated by amendment: registries retain the set of enacted rule ids (`enactedRuleIds`) for the lifetime of a `lockId`.
- **Expired locks and resources.** An expired lock can only be `Expire`d or `Cancel`led; it cannot be enacted and cannot be amended. Registries MAY exercise `Expire` with admin authority for cleanup, analogous to `LockedAmulet_ExpireAmulet`; `Expire` can only return funds to the authorizer. Instructions abandoned by an unresponsive authorizer are cleaned up the same way: registries MAY permit the admin alone to exercise `ConditionalLockInstruction_Withdraw` at or after `terms.expiresAt` (section 3.2). Registries whose holdings accrue a fee MUST provide an admin cleanup path for expired locks. Registries MUST NOT fire any rule after expiry.
- **Preimage disclosure.** A revealed preimage is visible to the stakeholders of the enactment transaction and to anyone they disclose it to. Every choice observer of `ConditionalLock_Enact` learns every preimage in `witness.preimages`, which is why `conditionalLock_enactExtraObservers` MUST NOT name parties beyond the accounts the outcome pays unless the instrument is public (section 3.9). Locks are single-use; a digest reused across locks is a wallet error, not a protocol weakness, but wallets SHOULD warn.
- **Privacy.** Digests, receivers, named parties, and lock context are visible to the lock's stakeholders and, through `Lock.context`, potentially to account providers. Wallets SHOULD keep `context` generic.
- **Authorization.** Enactment never requires the authorizer at enactment time; the authorizer's authority was granted at lock creation. Every choice's `actors` MUST be checked by implementations, as stated on each choice in section 3. Registries MUST ensure no path exists to move the locked funds other than the four choices and the expiry cleanup.

## Questions for the Community

This draft is posted to find out whether the primitive is needed and, if so, in what shape. Replies on cip-discuss are what should decide whether it proceeds, and they are the evidence this CIP's Rationale will eventually have to cite.

1. **Which guards do you actually need?** The draft fixes a closed set: a hash preimage, ledger time before and after a point, and a threshold of named parties. Is any of these unnecessary for your use case? Is anything missing that you would need, and that the lock's signatories can check at enactment without reference to another contract or to off-ledger data?
2. **Which outcomes do you actually need?** The draft offers return to the authorizer, release to legs fixed in the terms, and amounts chosen at release within a receiver set fixed in the terms. Does your use case need all three? Does it need bounded discretion at release at all, or are fixed legs enough?
3. **Would you adopt an out-of-tree package before it is in Splice?** The interface package and an implementation over `TestTokenV2` exist today under Apache-2.0 and can be taken as a dependency now. Would your registry, wallet, or application depend on them ahead of a Splice release, and what would you need in order to be willing to: a stable package id, a version policy, conformance tests, something else?
4. **Where does this rank against digesting V2?** V2 is a large change and the ecosystem is still absorbing it. Is a conditional lock something you want now, something you want once V2 has settled, or something you would rather see solved another way?
5. **Who would sponsor it?** Standards-track work needs someone to carry it and maintainers willing to schedule the Splice and Canton Coin work. If you would sponsor, co-author, implement, or pilot it, please say so on the thread.

## Changelog

2026-09-10 - Initial draft.
2026-09-16 - Round two after the first review of canton-network/splice PR 7294: flattened guards to a two-level `anyOf`/`allOf` shape (`Guard`, `Alternative`, `Rule.anyOf`); renamed `owner` to `authorizer` (`LockTerms.authorizer`); removed the expiry-time alternate-outcome field, `Expire` now always unlocks to the authorizer (`LockTerms`, `ConditionalLock_Expire`); merged the two release-outcome constructors into `Outcome_Release` with fixed and enactor-supplied legs (`Outcome`, `ConditionalLock_Enact.legs`); added `Leg.legId` and `Leg.meta` (`Leg`); generalized acceptance to `pendingApprovals` and `availableActions` (`ConditionalLockInstructionView`, `ConditionalLockInstruction_Accept`); attributed guard checking to the lock contract's signatories (`Guard`, section 3.3). Added: a view budget section on choice-observer functions; `Amend` semantics; a restated Reference Implementation describing what is implementable today versus what awaits the Splice maintainers; a reframed Motivation; a new worked example, escrowed DvP with a dispute window; and a Questions for the Community section. Added `lockId` to `ConditionalLockInstructionView` so wallets correlate an instruction across approvals. Adversarial review: amendments never pending, actors checks on every choice, preimage observer bound, named parties and receivers defined on LockTerms, enacted rule ids retained and exposed, holdingCids, change at result level, three-component transfer leg identifiers, max-named-parties, Leg.meta reserved keys rejected, blocked-receiver guidance.

## Copyright

This CIP is licensed under CC0-1.0: [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). Code in the reference implementation is licensed under Apache-2.0.
