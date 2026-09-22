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

This CIP adds one interface package to the Canton Network Token Standard, `splice-api-token-conditional-lock-v1`, letting a `Holding`'s holder attach a release policy to it: a set of rules, each pairing a condition with an outcome, unlock to the authorizer or release to fixed legs plus bounded discretion. A rule fires at most once and may consume part of the amount, leaving the remainder locked until expiry, when it only unlocks to the authorizer. The authorizer and every named party can cancel or amend the lock by unanimous consent.

The package defines a factory, a two-step approval instruction, the lock interface (`Enact`, `Expire`, `Cancel`, `Amend`), the holding representation while locked, event reporting through the CIP-0112 `EventLog`, and off-ledger registry endpoints. It modifies no existing package: any registry can implement it, and any V1 or V2 wallet already renders the locked holding correctly.

## Motivation

The token standard describes locks but does not let anyone create one. `Holding.lock` in CIP-0056 and CIP-0112 is view data: `holders`, `expiresAt`, `expiresAfter`, `context`. There is no standard choice to lock a holding, no standard statement of who may release it, and no standard release condition. Canton Coin exposes a registry-specific `LockedAmulet` whose unlock requires the owner and every lock holder to act together, with a timeout for the owner. No other registry is obliged to offer anything comparable, and no application can write one lock flow that works across registries.

### The use cases

**HTLC cross-chain legs.** A hash time-locked swap is atomic only if the Canton leg releases on the same preimage the other chain checks. *Who needs it:* market makers and bridge operators quoting a Canton instrument against an asset on Bitcoin, an EVM chain, or Solana, and the registries they quote; today the Canton side is a registry-specific contract or an off-ledger release.

**Escrow with a decision-maker.** Funds are locked by one party and awarded, in whole or part, by a named arbiter who is neither counterparty. *Who needs it:* marketplaces, freelance and RWA platforms, and dispute-resolution services, which today take title into an application-owned template, losing the holder's portfolio view.

**Vesting and tranche release.** One lock releases a fixed fraction at each of several dates and continues with the remainder, with no party choosing an amount or destination. *Who needs it:* token issuers paying contributors, investors, or grantees under a published schedule, and wallets that must show what is locked and when it opens.

**Collateral with top-up and default.** A pledge the pledgee releases on repayment and may claim after maturity, with amount and maturity both parties can adjust by consent. *Who needs it:* lending and margin applications, and custodians who need collateral to stay in the pledgor's account for reporting and tax treatment.

**Conditional payment on attestation.** Payment released to the payee when a named attestor acts, and only before a deadline. *Who needs it:* invoice financing, parametric insurance, and milestone payments, and any registry asked to support "pay on proof of delivery" without becoming a party to the delivery.

### What token standard V2 already covers

Token standard V2 (CIP-0112) allocations already cover the following, and this CIP does not re-cover them.

**Counterparties as their own executors.** `SettlementInfo.executors` is a party list configured per settlement, not a fixed third-party role, per CIP-0112 "Configurable Executors and Batch Settlement via SettlementFactory". A delivery versus payment between two counterparties, with both as the executors, needs no third party and works across registries. Same-ledger and cross-registry DvP without a venue is a V2 feature today.

**Venue-executed matched trades.** Where a venue matches orders, CIP-0112 "Improved User Flows with Trusted Venues" covers writing the executed trade to the chain with only the executor as signatory.

**Pre-funding.** CIP-0112 "Committed Allocations for Prefunded Trading and Iterated Settlement" covers funds committed ahead of the trade: `AllocationSpecification.committed` holds the funds until the executors settle or cancel, the deadline passes, or the admin expires the allocation.

**Executor-chosen legs and iterated settlement.** An allocation need not fix its legs in advance, per CIP-0112 "Committed Allocations for Prefunded Trading and Iterated Settlement": with iterated settlement enabled, the executors supply `extraTransferLegSides` at settlement, and the result is a new allocation carrying the change, so an off-chain order book settles repeatedly against one funded position with no custom contract code.

None of these needs a conditional lock, and this CIP is not an alternative to any of them.

### What token standard V2 cannot express

1. **Release conditioned on a fact the lock's signatories check, rather than on a party acting.** A preimage or a point in ledger time is checked by the signatories at release, not decided by a party. An allocation's `settlementDeadline` only bounds when parties may act, never itself releasing anything.
2. **More than one outcome over the same locked funds.** A lock carries a list of rules over one pool of funds, each with its own guard and outcome. Per CIP-0112 "Committed Allocations for Prefunded Trading and Iterated Settlement", an allocation authorizes one settlement whose legs the executors may re-choose, not alternative outcomes.
3. **Discretion over amounts bounded by the terms, not by the settlement role.** A lock can give amount discretion to a party with no other power over the funds, gated on a guard and bound to a receiver list fixed at creation. In an allocation, only the executor set chooses amounts, and its receivers (`TransferLegSide.otherside`) are supplied at settlement, not declared in the allocation.
4. **Partial consumption governed by the rule that fired.** A lock's continuation is determined by the rule that fired: it consumes exactly the legs released and continues without that rule (section 3.6). Per CIP-0112 "Committed Allocations for Prefunded Trading and Iterated Settlement", an allocation's iterated settlement instead returns the change to a new allocation whose split the executors choose.
5. **Amendment by unanimous consent.** `Amend` replaces the terms with the consent of the authorizer and every named party, adjusting the locked amount and requiring newly introduced receivers to act in the same transaction (section 3.6). Per CIP-0112 "Topping up Allocations", executors may rebalance a committed allocation's funding, but the authorizer cannot alter the legs or deadline, and funding changes are the executors' to make, not the affected parties'.

Canton expresses this more cleanly than an account-model chain: a lock is an attribute of the holding, so funds never leave the authorizer's portfolio, and release paths are pre-authorized at creation so a receiver or arbiter can enact without the authorizer's signature.

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
      -- length as `max-preimages` (CIP section 3.8). Every choice observer of
      -- `ConditionalLock_Enact` learns every listed preimage; see
      -- `conditionalLock_enactExtraObservers`.
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
        -- Every supplied leg MUST name a receiver here. MUST be duplicate-free.
        -- MUST NOT be longer than `max-legs` (CIP section 3.8). An empty list admits
        -- no enactor-supplied legs. `fixedLegs` and `receivers` MUST NOT both be
        -- empty.
        --
        -- The total released, `fixedLegs` plus the supplied legs, MUST be positive
        -- and MUST be at most the remaining amount. If less, the remainder stays
        -- locked and the lock continues without this rule.
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
      -- ^ Disjunction: the rule is enactable when at least one alternative is
      -- satisfied. MUST be non-empty. Registries advertise the maximum length as
      -- `max-alternatives-per-rule` (CIP section 3.8).
    outcome : Outcome
  deriving (Eq, Ord, Show, Serializable)

-- | The release policy, provided by the authorizer's wallet.
--
-- The **receivers** of terms are the accounts other than `authorizer` that appear as
-- `Leg.receiver` in any `fixedLegs` or in any `Outcome_Release.receivers`. The
-- **named parties** of terms are the parties of every receiver account, every party
-- in any `Rule.enactors`, and every party in any `Guard_Parties.parties`, excluding
-- the parties of `authorizer`. Registries advertise the maximum number of named
-- parties as `max-named-parties` (CIP section 3.8).
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
      -- ^ Change holdings created for the authorizer from the input holdings, if
      -- any, reported here rather than in `output`.
    meta : Metadata
      -- ^ Implementation-specific metadata, e.g. fees charged.
  deriving (Eq, Show, Serializable)

data ConditionalLockResult_Output
  = ConditionalLockResult_Pending with
      instructionCid : ContractId ConditionalLockInstruction
        -- ^ One or more approvals are required before the lock becomes active.
        -- Returned by `ConditionalLockFactory_Lock`, and by
        -- `ConditionalLockInstruction_Accept` while approvals remain outstanding;
        -- never by `ConditionalLock_Amend`.
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
        -- ^ The continuing lock, when funds remain. Its stakeholders follow from the
        -- remaining terms, so an enactor named only by the rule just fired MAY be
        -- unable to fetch it.
  | ConditionalLockResult_Failed with
      authorizerHoldingCids : [ContractId Holding]
        -- ^ Instruction rejected or withdrawn. The unlocked holdings returned to the
        -- authorizer. MAY be empty for registries that do not represent their
        -- holdings on-ledger.
  deriving (Eq, Show, Serializable)
```

### 3. Interfaces

#### 3.1 `ConditionalLockFactory`

```daml
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
        -- sets a key the registry is required to set (CIP section 3.7); rule,
        -- alternative, guard, leg, and named-party counts are within the advertised
        -- limits (CIP section 3.8).
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

- The factory MUST validate `terms` as stated on `ConditionalLockFactory_Lock.terms` above.
- The factory MUST also reject terms where any `Leg.meta` sets a key the registry is required to set (section 3.7).
- The number of named parties MUST be within the advertised `max-named-parties` (section 3.8); registries whose lock representation bounds lock holders SHOULD set it to that bound.
- **Receivers** and **named parties** are as defined on `LockTerms` (section 2).
- Change holdings from the input holdings are reported in `ConditionalLockResult.authorizerChangeCids`, whatever the output. A rejected or withdrawn instruction returns the locked funds in `ConditionalLockResult_Failed.authorizerHoldingCids`.
- If every receiver's `actors` already include the parties the registry requires, or the account holds a recognized standing pre-approval, the factory SHOULD complete in one step and return `ConditionalLockResult_Locked`.
- Otherwise the factory MUST return `ConditionalLockResult_Pending` with a `ConditionalLockInstruction`, whose `pendingApprovals` names accounts still owed approval and whose `availableActions` reports who may give it. Input holdings SHOULD be locked to the parties the registry requires for `terms.authorizer` and the named parties while pending, with `expiresAt` set to `terms.expiresAt`.

#### 3.2 `ConditionalLockInstruction`

```daml
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
        -- unauthorized withdrawal. Registries MAY additionally permit the admin
        -- alone at or after `terms.expiresAt` for cleanup; funds return only to the
        -- authorizer.
      extraArgs : ExtraArgs
    observer conditionalLockInstruction_withdrawExtraObservers this arg
    controller actors
    do conditionalLockInstruction_withdrawImpl this self arg
```

The registry assigns `lockId` when it creates the `ConditionalLockInstruction`; wallets use it to correlate an instruction across approvals, and it carries unchanged into `ConditionalLockView.lockId` once active (section 3.3). `ConditionalLockInstruction_Accept` MUST fail at or after `terms.expiresAt`. Registries MUST allow the authorizer to withdraw a pending instruction at or after `terms.expiresAt` regardless of approver action, so pending instructions cannot pin funds indefinitely, and MAY additionally permit the admin alone to withdraw then for cleanup, resolving to `Failed`.

#### 3.3 `ConditionalLock`

```daml
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

  -- | Choice observers for `ConditionalLock_Enact`. `ConditionalLock_Enact`'s
  -- arguments include `witness.preimages`, so every choice observer learns every
  -- revealed preimage. Implementations MUST NOT return parties beyond those of the
  -- accounts the enacted outcome pays unless the instrument is public: none for
  -- `Outcome_Unlock`, the parties of the receiver accounts of the released legs for
  -- `Outcome_Release`.
  --
  -- This function is evaluated before the choice body. It MUST be total and MUST
  -- NOT fail. A `ruleId` that is not in `terms.rules`, because it is unknown or
  -- already fired, MUST yield the empty list and let the body reject the exercise.
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
        -- the authorizer account, or, where the registry permits admin-only cleanup,
        -- the admin alone; funds return only to the authorizer either way.
        -- Implementations MUST check these parties to avoid unauthorized expiry.
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
    -- `newTerms` introduces.
    with
      newTerms : LockTerms
        -- ^ `authorizer` and `instrumentId` MUST equal the current ones. `amount` MUST
        -- NOT be less than the current `terms.amount`; the increase MUST be funded by
        -- `additionalInputHoldingCids` net of any fee the registry charges for the
        -- amendment, with the remainder returned as change in
        -- `ConditionalLockResult.authorizerChangeCids` and the fee reported in
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

The signatories of a `ConditionalLock` MUST include the registry admin, the parties the registry requires to move funds out of `terms.authorizer`, and, for every approved receiver account, the parties that gave that approval (section 3.2), with the account's other parties as observers; guards are therefore checked by those parties at enactment, and the enactor supplies the `witness` without being trusted to evaluate it.

`ConditionalLockView.enactedRuleIds` is the registry's record of fire-once across continuations and amendments.

#### 3.4 Holding representation while locked

A registry representing holdings on-ledger MUST, while a lock is active, represent the locked funds as the `Holding`s in `holdingCids`, in `terms.authorizer`, summing to `terms.amount`, with `lock` set on each to:

- `holders`: the named parties of the terms (`LockTerms`, section 2); if none besides the authorizer, `holders` is the registry admin alone;
- `expiresAt = Some terms.expiresAt`;
- `expiresAfter = None`;
- `context`: a short human-readable description, e.g. `hashlock to <receiver>` or `vesting, 4 tranches`.

The holding's `meta` MUST carry `splice.lfdecentralizedtrust.org/lock-context` with the same text; `ConditionalLock` MAY be the same contract as the `Holding`, as `LockedAmulet` does, or a separate one referencing it. This keeps the lock invisible to existing wallets, which already render a locked holding as such; a registry with no on-ledger holdings reports the same information through its own view, with `holdingCids` empty.

#### 3.5 Guard evaluation

A rule is enactable when some alternative in `anyOf` is satisfied; an alternative is satisfied when every guard in its `allOf` is. Guards are evaluated at enactment against ledger time, the `witness`, and the `actors`:

- `Guard_Preimage`: satisfied if some entry of `witness.preimages`, lowercased, is exactly 32 bytes of hex whose digest under `algorithm` equals `digest`, computed over the decoded bytes rather than the hex text, so the same preimage satisfies an EVM `sha256(bytes32)` or a Bitcoin `OP_SHA256` lock.
- `Guard_After`: satisfied if ledger time is at or after `time`.
- `Guard_Before`: satisfied if ledger time is strictly before `time`.
- `Guard_Parties`: satisfied if at least `threshold` distinct members of `parties` are among `actors`.

Registries MUST support all guard kinds, at least eight alternatives per rule and eight guards per alternative, and MUST advertise the values they support (section 3.8). Guards are a closed set: no arithmetic, no contract references, no repetition, no nesting beyond `anyOf`/`allOf`.

`ConditionalLockView.availableActions` entries for `CLA_Enact` mean the rule may be enacted, not that it is currently satisfied (section 3.3).

#### 3.6 Outcome enactment and continuation

On `Enact` of rule `r` with remaining amount `a`, `Outcome_Unlock` returns `a` to the authorizer unlocked and terminates the lock. `Outcome_Release` releases `fixedLegs` plus the supplied `legs` under the constraints stated on `Outcome_Release` and `ConditionalLock_Enact.legs`; if the total is less than `a`, the lock continues with `a` minus the total and `terms.rules` minus `r`, otherwise it terminates. A leg to `terms.authorizer` is an unlock.

`Expire` returns the remaining amount to the authorizer unlocked and terminates the lock; its actors are as stated on `ConditionalLock_Expire`. Registries MUST NOT fail an `Expire` for reasons attributable to any party other than the authorizer.

Creating a receiver holding is a transfer, so the registry's transfer rules (allow lists, pause status, provider controls) apply and registries MAY fail an enactment on them. Conservation is checked against the terms; registries whose holdings carry fees MAY deliver reduced amounts and MUST report the deduction in the result `meta`.

`Cancel` and `Amend` are authorized and validated as stated on their choices. In addition, `Amend` MUST NOT reduce the locked amount (partial release is `Enact`, full release is `Cancel`), and checking against `terms.amount` rather than the holding balance keeps fee decay out of the rule; `newTerms.requestedAt` MUST be in the past and SHOULD be the amendment's timestamp. Every successful choice archives the lock and its backing holdings and creates a continuation when funds remain (section 3.3); the continuation keeps `lockId` and `enactedRuleIds`.

All time comparisons use ledger time. Registries SHOULD accept holdings whose lock has expired as transfer inputs, per the `Holding.lock` doc comment in `splice-api-token-holding-v2`, so `Expire` can be combined with use in one transaction.

#### 3.7 Event reporting

V2 registries MUST report every holdings change these choices cause through `EventLog_HoldingsChange` (CIP-0112 "EventLog for Transaction Parsing"). Creation, approval, amendment, expiry, cancellation, and legs to `terms.authorizer` are holdings changes on `terms.authorizer` with no transfer leg. Each enacted leg to another receiver is a holdings change on `terms.authorizer` and one on the receiver, each carrying a `TransferLegSide` with the identifier `<lockId>/<ruleId>/<legId>` and the leg's `meta`.

A leg's two sides MUST share an identifier and distinct legs, including across enactments, MUST have distinct ones, as CIP-0112 requires; `lockId`, `Rule.id`, and `Leg.legId` MUST be non-empty and MUST NOT contain `/`. The registry issues `lockId` at instruction (section 3.2); it MUST be distinct per lock and MUST remain stable across approvals, continuations, and amendments. Because a rule id fires at most once per `lockId` and leg ids are unique within an enactment, the three components suffice.

`TransferLegSide.meta` MUST contain every key of `Leg.meta`. `Leg.meta` MUST NOT set `splice.lfdecentralizedtrust.org/tx-kind`, `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`, or any other reserved key under `splice.lfdecentralizedtrust.org/conditional-lock/`, and registries MUST reject such terms at creation and amendment. `splice.lfdecentralizedtrust.org/reason` on a leg is not reserved and labels the leg for wallets.

Choice-result and holding `meta` MUST carry `splice.lfdecentralizedtrust.org/tx-kind`: `lock` for creation, approval, and amendment; `transfer` for enactments creating receiver holdings; `unlock` for unlocks, cancellation, and expiry. A holding's `meta` is fixed when the holding is created, so the backing holding of a continuation carries `lock` even when the enactment that created it reports `transfer`. Enactment results MUST carry `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`. `splice.lfdecentralizedtrust.org/reason` SHOULD be set on reject, withdraw, cancel, expire, and amend.

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

- `POST /registry/conditional-lock/v1/lock-factory`: returns the factory contract id, choice context, and disclosed contracts for `ConditionalLockFactory_Lock`, shaped like the CIP-0056 transfer-factory endpoint;
- `POST /registry/conditional-lock/v1/{lockInstructionId}/choice-contexts/{accept|reject|withdraw}`: returns the choice context and disclosed contracts for the named choice on a `ConditionalLockInstruction`;
- `POST /registry/conditional-lock/v1/{lockContractId}/choice-contexts/{enact|expire|cancel|amend}`: returns the choice context and disclosed contracts for the named choice on a `ConditionalLock`, addressed by its contract id rather than by `ConditionalLockView.lockId`.

The OpenAPI file `conditional-lock-v1.yaml` is part of the reference implementation.

#### 3.9 View budget

Canton's transaction cost is driven by the number of views a transaction generates, created whenever a called choice has informees the calling choice does not (CIP-0112 "Guidelines & Interfaces for Performance Optimization"). Registries MUST implement the eight `*ExtraObservers` functions of section 3, each setting its choice's observers, and SHOULD do so such that each choice generates a single view.

Usually this means:

- `ConditionalLockFactory_Lock`: `terms.authorizer`'s parties and those of every account whose approval the registry expects in the same transaction.
- `ConditionalLockInstruction_Accept`, `_Reject`, `_Withdraw`: `terms.authorizer`'s parties and those of the accounts still in `pendingApprovals`.
- `ConditionalLock_Enact`: the parties of the accounts the outcome pays: none for `Outcome_Unlock`, the `fixedLegs` and enactor-supplied `legs` receiver parties for `Outcome_Release`.
- `ConditionalLock_Expire`: none; funds return to the authorizer, already a signatory, as for `Outcome_Unlock`.
- `ConditionalLock_Cancel` and `ConditionalLock_Amend`: the named parties whose consent the choice already requires, plus for `Amend` those `newTerms` introduces.

An `ExtraObservers` function is evaluated before the choice body; it MUST be total and MUST NOT fail. In particular, `ConditionalLock_Enact` with a `ruleId` not in `terms.rules` MUST yield the empty list and leave the rejection to the choice body.

Registries whose instruments do not require confidentiality between a lock's stakeholders MAY set all named parties as choice observers on every choice, per CIP-0112's recommendation for such assets; registries that do require confidentiality MUST NOT. In particular, a `Guard_Preimage` enactment reveals the preimage to every informee, so `conditionalLock_enactExtraObservers` MUST NOT name parties beyond the accounts the outcome pays unless the instrument is public.

The intended budget is one view per exercised choice; the escrowed DvP of section 4 exercises two `ConditionalLock_Enact` choices in one transaction and SHOULD therefore cost at most three views.

These functions bound visibility, not authorization: a choice observer is not an actor, and naming a party here never entitles it to enact a rule.

### 4. Worked terms

Written in shorthand: accounts are shown as their owning party, and `Leg` is shown without its `meta`, which is empty in every example.

- **HTLC leg.** One rule: enactors `[bob]`, one alternative `allOf [Guard_Preimage Sha256 H]`, outcome `Outcome_Release with fixedLegs = [Leg "claim" bob amount]; receivers = []`.
- **Escrowed DvP with a dispute window.** Alice locks X for Bob with `deadline < expiresAt` and two rules. Rule `settle`: enactors `[alice, bob]`, one alternative `allOf [Guard_Parties [alice, bob] 2, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "delivery" bob amount]; receivers = []`, terminating the lock. Rule `award`: enactors `[arbiter]`, one alternative `allOf [Guard_After deadline, Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [alice, bob]`. Bob's lock of Y on registry B is symmetric, and the two `settle` enactments are exercised in one Canton transaction. The rules are mutually exclusive in time: `settle` only before the deadline, `award` only from the deadline to expiry, and only `Expire` after expiry, returning the remainder to Alice. A partial award consumes the `award` rule, so the arbiter decides once. One pool of funds, two conditions, two outcomes.
- **Arbiter escrow.** One rule: enactors `[arbiter]`, one alternative `allOf [Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [buyer, seller]`. The arbiter can award all to one side or split.
- **Vesting.** Four rules, each with enactors `[grantee]`, one alternative `allOf [Guard_After T_k]`, and outcome `Outcome_Release with fixedLegs = [Leg "tranche-k" grantee (amount/4)]; receivers = []`. Each fires once; the lock continues with the remainder, and only the grantee submits the enactment once the date has passed.
- **Collateral.** Rule `repaid`: enactors `[pledgee]`, one alternative `allOf [Guard_Parties [pledgee] 1]`, outcome `Outcome_Unlock`. Rule `default`, enactable between maturity and expiry (`maturity < expiresAt`): enactors `[pledgee]`, one alternative `allOf [Guard_After maturity, Guard_Parties [pledgee] 1]`, outcome `Outcome_Release with fixedLegs = [Leg "default" pledgee amount]; receivers = []`. Margin top-up and maturity extension go through `Amend`, reusing the `default` rule's id, legal since it has not fired and so is not in `enactedRuleIds`.
- **Conditional payment.** One rule, with `deadline <= expiresAt`: enactors `[payee]`, one alternative `allOf [Guard_Parties [attestor] 1, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "payment" payee amount]; receivers = []`.

## Rationale

**A release policy rather than an HTLC.** Escrow, vesting, collateral, and conditional payment are an HTLC with different guards and more than one outcome. One data model covers all of them.

**A closed guard set with a fixed two-level shape.** A rule is a disjunction (`anyOf`) of conjunctions (`allOf`) of leaf guards: no arithmetic, no state, no contract references, no recursion. A wallet renders a two-level list, and registries advertise limits as CIP-0112 bounds transfer legs.

**Partial consumption instead of nested terms.** A rule fires once and the lock continues with the remainder, so vesting is a flat rule list rather than a tree of successor terms.

**Conditions as well as executors.** CIP-0112 already lets counterparties act as their own executors, which settles delivery versus payment. It cannot express a release that depends on a fact rather than a party: a preimage, or a point in ledger time. Where a party does decide, `Guard_Parties` names it and the outcome bounds its discretion to a receiver set fixed in the terms.

**Atomicity instead of cross-lock guards.** Two locks enacted in one transaction commit or fail together, so a guard on another lock's state adds nothing.

**Expiry always unlocks.** A directed outcome on expiry is an ordinary `Guard_After` rule naming the beneficiary, with `expiresAt` as the safety valve behind it. In CIP-0112, expiry, withdrawal, and cancellation likewise only return funds to the authorizer.

**One release outcome.** `Outcome_Release` carries fixed legs and a bounded discretionary part under one conservation check, so a fixed fee plus a discretionary award is one rule. The enactor may still release the fixed legs alone (Security Considerations, "Enactor discretion"). CIP-0112 allocations use the same shape: legs fixed at authorization, legs supplied at execution, one budget.

**A new package rather than a change to `splice-api-token-holding-v2`.** Adding choices to `Holding` would break every implementation. A separate package follows the CIP-0112 evolution model: registries opt in, wallets discover support through `supportedApis`, and the on-ledger footprint is the existing `Lock` view.

**What a registry must implement.** Three interfaces and the holding representation of section 3.4, which is the `Lock` view CIP-0056 already defines. Any registry that implements CIP-0112 can implement this package at the same Daml-LF target. Every guard kind and outcome is mandatory; only the numeric limits of section 3.8 are registry-specific.

**Approvals.** Creating a receiver holding requires the receiver's authority, as for transfers, and a registry MAY also require the account's provider. The instruction names the accounts whose approval is outstanding and reports who may act through `availableActions`.

**Byte-domain hashing.** `DA.Text.sha256` hashes UTF-8 text; `DA.Crypto.Text.sha256` and `keccak256` hash the decoded bytes of a hex string, which is what external-chain hashlocks compute. The preimage is therefore 32 bytes of hex, lowercased, and both algorithms are mandatory: SHA-256 for Bitcoin, Lightning, and EVM HTLCs, Keccak-256 for EVM-native counterparties.

**Relation to CIP-0105 and CIP-0116.** Those CIPs lock Canton Coin per PartyId for Super Validator weight and Featured App eligibility. This CIP is registry-agnostic and has no governance semantics; a Canton Coin implementation would reuse `LockedAmulet` mechanics without touching DSO governance.

**Alternatives considered.**

- Application-owned escrow templates: funds leave the authorizer's portfolio and change tax and custody treatment; CIP-0105 requires locking to work from self-custody and custodial wallets alike.
- Committed allocations with the counterparty as executor: right for a trade with known or settlement-chosen legs; no fact-checked release, no second outcome, no receiver bound on discretion.
- `TransferPreapproval` plus off-ledger coordination: no on-ledger enforcement of the condition or the expiry.
- Registry-specific lock contracts such as `LockedAmulet`: correct for one registry, unusable across registries, not condition-aware.
- Cross-lock and oracle-data guards: unnecessary given atomic enactment and `Guard_Parties`; deferred.

## Backwards Compatibility

The CIP is additive. No existing package, interface, choice, or off-ledger endpoint changes. Registries that do not implement the package are unaffected; wallets that do not implement it still display conditionally locked holdings as locked holdings and fall back to the generic rendering CIP-0056 prescribes for choices outside the standard (`lock` is a new `tx-kind` value). Applications that need the primitive can test for it per instrument through `supportedApis`.

## Reference Implementation

An Apache-2.0 reference implementation of this revision is at https://github.com/tankcdr/conditional-holding-lock: the `splice-api-token-conditional-lock-v1` package as specified here, an implementation of it over the published `TestTokenV2` package, the registry OpenAPI file `conditional-lock-v1.yaml`, and Daml Script proofs of the interface's properties, including byte-domain hash vectors shared with EVM and Solana reference programs. It can be taken as a dependency by any registry or application. Adding the package to the Splice `token-standard` directory, extending `TestTokenV2` in the Splice tree, wallet support, and a Canton Coin implementation follow when the maintainers schedule them and are required before this CIP can move to Final.

## Security Considerations

- **Timelock ordering.** In a two-chain swap the leg released first by the preimage must have the shorter expiry, leaving the party who learns it on-ledger time to claim on the other chain.
- **Blocked receivers.** Enactment is a transfer, so a paused or blocked receiver account fails the rule and the funds return to the authorizer at expiry; in a two-chain swap the external leg stays claimable. Counterparties SHOULD confirm receiver status before funding the external leg, and registries SHOULD surface it through the choice-context endpoint (section 3.8).
- **Submission delay.** A registry's delay between preparation and execution (up to 24 hours on Canton Coin under CIP-0107) shrinks the enactment window. Wallets MUST allow for it when choosing `expiresAt` and `Guard_Before`, and registries SHOULD publish `min-duration` accordingly.
- **Authoring errors.** A rule whose `fixedLegs` exceed the remaining amount cannot fire. Wallets SHOULD check that every firing sequence stays enactable, and registries MAY reject terms whose legs exceed `amount`.
- **Enactor discretion.** With non-empty `receivers` the enactor chooses amounts within the receiver set and the remainder net of `fixedLegs`; authorizers SHOULD gate it with `Guard_Parties`. Supplied legs MAY be empty, so the enactor can take `fixedLegs` alone and leave the rest to expire; authorizers SHOULD size fixed fees with that in mind.
- **Preimage evaluation.** The lock's signatories hash and compare the witness (section 3.3); the enactor supplies it and cannot make a guard appear satisfied.
- **Amendment.** `Amend` is unanimous and never returns `Pending`. A fired rule cannot be reinstated, because `enactedRuleIds` persists for the lifetime of the `lockId`.
- **Expired locks.** An expired lock can only be expired or cancelled, and registries MUST NOT fire any rule after expiry. Registries MAY let the admin alone `Expire` a lock or `Withdraw` an abandoned instruction at or after `expiresAt`, since funds only return to the authorizer, and registries whose holdings accrue fees MUST provide that cleanup path.
- **Preimage disclosure.** A revealed preimage is visible to the enactment's stakeholders; section 3.9 bounds the choice observers. A digest reused across locks is a wallet error, and wallets SHOULD warn.
- **Privacy.** Digests, receivers, named parties, and `Lock.context` are visible to the lock's stakeholders and, through `context`, to account providers. Wallets SHOULD keep `context` generic.
- **Authorization.** The authorizer's authority is granted at creation and never required at enactment. Implementations MUST check every choice's `actors` (section 3) and MUST ensure no other path moves locked funds.

## Changelog

2026-09-10 - Initial draft.

2026-09-18 - Review round two, resolving the review comments on the previous revision of `ConditionalLockV1.daml` in canton-network/splice#7294, cited by their line in that revision: flattened `Guard` into a leaf type with `Alternative.allOf` and `Rule.anyOf` (line 47), renamed `owner` to `authorizer` (line 91), removed the fallback outcome so `Expire` returns the remainder to the authorizer (line 102), merged the release outcomes into `Outcome_Release` with `fixedLegs` and enactor-supplied legs bounded by `receivers` (line 250), added `Leg.legId` and `Leg.meta` (line 61), generalized acceptance to an approver `Account` with `pendingApprovals` and `availableActions` (line 194), reworded guard evaluation as a check by the lock's signatories (line 23), fixed `Amend` semantics, specified the eight `*ExtraObservers` functions, added `lockId`, `enactedRuleIds`, and `holdingCids`, and added `authorizerHoldingCids` to `ConditionalLockResult_Failed`.

## Copyright

This CIP is licensed under CC0-1.0: [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). Code in the reference implementation is licensed under Apache-2.0.
