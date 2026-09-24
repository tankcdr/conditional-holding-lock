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

This CIP adds one interface package to the Canton Network Token Standard, `splice-api-token-conditional-lock-v1`, letting a holder attach a release policy to a `Holding`: rules pairing a condition with an outcome, an unlock to the authorizer or a release to fixed legs plus bounded discretion. A rule fires at most once and may consume part of the amount; the remainder stays locked until expiry, when it only unlocks to the authorizer. The authorizer and every named party can cancel or amend the lock by unanimous consent.

The package defines a factory, a two-step approval instruction, the lock interface (`Enact`, `Approve`, `Expire`, `Cancel`, `Amend`), the locked holding representation, `EventLog` reporting, and registry endpoints, and modifies no existing package: any registry can implement it, and any V2 wallet, or V1 wallet where the registry also implements `HoldingV1`, already renders the locked holding as locked.

## Motivation

The token standard describes locks but lets no one create one: `Holding.lock` (CIP-0056, CIP-0112) is view data, and no standard choice locks a holding under a release condition. CIP-0112 allocations hold funds for a settlement their executors perform, and the draft Super Validator and Featured App locking CIP (canton-foundation/cips#250) locks Canton Coin for an unlock its controllers approve; neither lets an application state a condition the lock's signatories check, in a form every registry implements alike. Canton Coin's `LockedAmulet` is registry-specific, and no other registry is obliged to offer an equivalent, so no lock flow works across registries.

### The use cases

**HTLC cross-chain legs.** A hash time-locked swap is atomic only if the Canton leg releases on the same preimage the other chain checks. *Who needs it:* market makers, bridge operators, and registries pricing Canton instruments against Bitcoin, EVM, or Solana assets.

**Escrow with a decision-maker.** Funds locked by one party are awarded, in whole or part, by an arbiter who is neither counterparty. *Who needs it:* marketplaces, freelance and RWA platforms, and dispute services, which today take title into application templates.

**Vesting and tranche release.** One lock releases a fixed fraction on each of several dates; no party chooses an amount or destination. *Who needs it:* issuers with published schedules, and the wallets that display them.

**Collateral with top-up and default.** A pledge the pledgee releases on repayment and may claim after maturity, with amount and maturity adjustable by mutual consent. *Who needs it:* lending, margin, and custody applications keeping collateral in the pledgor's account.

**Conditional payment on attestation.** Payment released to the payee when a named attestor acts, and only before a deadline. *Who needs it:* invoice financing, parametric insurance, and milestone payments.

### What token standard V2 already covers

CIP-0112 allocations already cover delivery versus payment with both counterparties as executors, because `SettlementInfo.executors` is configured per settlement ("Configurable Executors and Batch Settlement via SettlementFactory"); venue-executed matched trades, where creating the allocation authorizes the trade ("Improved User Flows with Trusted Venues"); pre-funding through `AllocationSpecification.committed` ("Committed Allocations for Prefunded Trading and Iterated Settlement"); and executor-chosen legs through `extraTransferLegSides`, settling repeatedly against one funded position ("Committed Allocations and Iterated Settlement"). None of these needs a conditional lock, and this CIP replaces none of them.

### What token standard V2 cannot express

1. **Release on a fact, not on a party acting.** The lock's signatories check a preimage or a point in ledger time at release; an allocation's `settlementDeadline` only bounds when parties may act.
2. **Several outcomes over the same funds.** A lock carries several rules over one pool, each with its own guard and outcome; an allocation authorizes one settlement whose legs the executors may re-choose.
3. **Amount discretion bounded by the terms.** A lock can give amount discretion to a party with no other power over the funds, gated on a guard and bound to receivers fixed at creation; in an allocation only the executors, under iterated settlement, choose amounts and receivers (`TransferLegSide.otherside`) at settlement.
4. **Partial consumption governed by the rule that fired.** A lock releases exactly the rule's legs and continues without that rule (section 3.6); iterated settlement returns the change to a new allocation whose split the executors choose.
5. **Amendment by unanimous consent.** `Amend` replaces the terms, and may add funds, with the consent of the authorizer and every named party, new receivers acting in the same transaction (section 3.6); no allocation choice amends terms; iterated settlement tops up through a second allocation the executors merge (CIP-0112 "Topping up Allocations").

A lock is an attribute of the holding, so the funds stay in the authorizer's portfolio while locked, and release paths are authorized at creation, so an enactor needs no signature from the authorizer.

## Specification

### 1. Package

New Daml package `splice-api-token-conditional-lock-v1`, module `Splice.Api.Token.ConditionalLockV1`, depending on `splice-api-token-metadata-v1` and `splice-api-token-holding-v2`, built like the V2 packages (Daml-LF 2.1, explicit serializability) and added to Splice's `token-standard` directory under their license and versioning practice.

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
        -- ^ Satisfied when at least `threshold` of `parties` are among the acting parties
        -- of `ConditionalLock_Enact`: its `actors` and the approvers recorded for the
        -- enacted rule and legs (`ConditionalLockView.approvals`). MUST satisfy
        -- 1 <= threshold <= length parties. A `threshold` of 1 expresses any one of
        -- these parties.
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
      -- ^ Parties entitled to enact this rule. At least one MUST be among the acting
      -- parties of `ConditionalLock_Enact`. MUST be non-empty and duplicate-free.
    anyOf : [Alternative]
      -- ^ Disjunction: the rule is enactable when at least one alternative is
      -- satisfied. MUST be non-empty. Registries advertise the maximum length as
      -- `max-alternatives-per-rule` (CIP section 3.8).
    outcome : Outcome
  deriving (Eq, Ord, Show, Serializable)

-- | Approval of one enactment of a rule, recorded under a lock by
-- `ConditionalLock_Approve`.
data Approval = Approval with
    ruleId : Text
      -- ^ The approved rule.
    legs : [Leg]
      -- ^ The approved enactor-supplied legs, in the order they are supplied to
      -- `ConditionalLock_Enact.legs`. The approval counts only for an enactment of
      -- `ruleId` with exactly these legs.
    approvers : [Party]
      -- ^ Non-empty, duplicate-free list of parties that approved, each in the rule's
      -- `enactors` or in a `Guard_Parties` of its `anyOf`.
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

-- | Result of instructing, enacting, approving, expiring, cancelling, or amending a lock.
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
        -- ^ The active lock. For `ConditionalLock_Approve`, the lock carrying the
        -- recorded approval, under the same `lockId`.
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

- The factory MUST validate `terms` as stated on `ConditionalLockFactory_Lock.terms`, which covers the named-party count and the reserved `Leg.meta` keys (section 3.7). Registries whose lock representation bounds lock holders SHOULD set `max-named-parties` to that bound.
- If every receiver's `actors` already include the parties the registry requires, or the account holds a recognized standing pre-approval, the factory SHOULD complete in one step and return `ConditionalLockResult_Locked`.
- Otherwise the factory MUST return `ConditionalLockResult_Pending` with a `ConditionalLockInstruction` whose `pendingApprovals` names the accounts still owed approval and whose `availableActions` reports who may give it. Input holdings SHOULD be locked to the parties the registry requires for `terms.authorizer` and the named parties while pending, with `expiresAt` set to `terms.expiresAt`.

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

`lockId` is as stated on `ConditionalLockInstructionView.lockId`, and expiry as stated on `ConditionalLockInstruction_Accept` and `ConditionalLockInstruction_Withdraw`, so a pending instruction cannot pin funds indefinitely.

#### 3.3 `ConditionalLock`

```daml
-- | Actions available on a conditional lock.
data ConditionalLockAction
  = CLA_Enact with
      ruleId : Text
        -- ^ The rule that can be enacted.
  | CLA_Approve with
      ruleId : Text
        -- ^ The rule whose enactment can be approved.
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
    approvals : [Approval]
      -- ^ Approvals recorded by `ConditionalLock_Approve`, at most one entry per
      -- `(ruleId, legs)` and each party in at most one entry per rule. Registries MUST
      -- retain the approvals of rules still in `terms.rules` across continuations, MUST
      -- drop those of a rule when it fires, and MUST clear all of them on
      -- `ConditionalLock_Amend`.
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
      -- against ledger time and the witness they hold. `CLA_Approve` has one entry per
      -- rule with a `Guard_Parties` in its `anyOf`, one group per party entitled
      -- to approve it.
    meta : Metadata
  deriving (Eq, Show, Serializable)

interface ConditionalLock where
  viewtype ConditionalLockView

  conditionalLock_enactImpl : ContractId ConditionalLock -> ConditionalLock_Enact -> Update ConditionalLockResult
  conditionalLock_expireImpl : ContractId ConditionalLock -> ConditionalLock_Expire -> Update ConditionalLockResult
  conditionalLock_cancelImpl : ContractId ConditionalLock -> ConditionalLock_Cancel -> Update ConditionalLockResult
  conditionalLock_amendImpl : ContractId ConditionalLock -> ConditionalLock_Amend -> Update ConditionalLockResult
  conditionalLock_approveImpl : ContractId ConditionalLock -> ConditionalLock_Approve -> Update ConditionalLockResult

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

  -- | Choice observers for `ConditionalLock_Approve`. Usually the named parties of
  -- the current terms, which observe the lock the choice replaces. It MUST be total
  -- and MUST NOT fail; a `ruleId` that is not in `terms.rules` MUST yield the empty
  -- list and let the body reject the exercise.
  conditionalLock_approveExtraObservers : ConditionalLock_Approve -> [Party]

  nonconsuming choice ConditionalLock_Enact : ConditionalLockResult
    -- ^ Fire one rule. The acting parties are `actors` together with the approvers
    -- recorded in `approvals` for exactly this `ruleId` and `legs`. Implementations
    -- MUST fail if ledger time is at or after `terms.expiresAt`; if no party in the
    -- rule's `enactors` is among the acting parties; if no alternative in the rule's
    -- `anyOf` is satisfied (CIP section 3.5); or if `legs` are not valid for the
    -- outcome (CIP section 3.6).
    with
      ruleId : Text
      actors : [Party]
        -- ^ Together with the recorded approvers, MUST include at least one of the
        -- rule's `enactors`. Implementations MUST check these parties to avoid
        -- unauthorized enactment.
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
    -- lock, which retains `lockId` and carries no `approvals`. Implementations MUST
    -- fail at or after the current `terms.expiresAt`.
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

  nonconsuming choice ConditionalLock_Approve : ConditionalLockResult
    -- ^ Record an approval of one enactment of a rule, counted by
    -- `ConditionalLock_Enact`. Result is `Locked`, with a new `lockCid` under the same
    -- `lockId`. The recorded approvers are the parties in `actors` that are in the rule's
    -- `enactors` or in a `Guard_Parties` of its `anyOf`; approving the same
    -- `(ruleId, legs)` again adds them to that approval. Approvals are irrevocable, and
    -- a party approves at most one list of legs per rule. Implementations MUST fail if
    -- ledger time is at or after `terms.expiresAt`; if `ruleId` is not in
    -- `terms.rules`; if the rule has no `Guard_Parties`; if no party in `actors` would
    -- be recorded that is not already recorded for `(ruleId, legs)`; if a party to be
    -- recorded has approved the rule with other legs; or if `legs` are not valid for
    -- the outcome (CIP section 3.6).
    with
      ruleId : Text
      legs : [Leg]
        -- ^ The enactor-supplied legs approved, under the same constraints as
        -- `ConditionalLock_Enact.legs`; so empty for an `Outcome_Unlock` and for an
        -- `Outcome_Release` with empty `receivers`.
      actors : [Party]
        -- ^ The parties approving. Implementations MUST check these parties to avoid
        -- unauthorized approval.
      extraArgs : ExtraArgs
    observer conditionalLock_approveExtraObservers this arg
    controller actors
    do conditionalLock_approveImpl this self arg
```

The choices are nonconsuming, following CIP-0112, so that implementations control consumption. On success, implementations MUST archive the `ConditionalLock` and the backing holdings in the same transaction, creating a continuation lock and holdings when funds remain; `Approve` instead replaces the lock under the same `lockId`, and clients use the returned `lockCid`. The continuation keeps `lockId`, `enactedRuleIds`, and the approvals of the rules that remain.

The signatories of a `ConditionalLock` MUST include the registry admin, the parties the registry requires to move funds out of `terms.authorizer`, and, for every approved receiver account, the parties that gave that approval (section 3.2), with the account's other parties as observers; guards are therefore checked by those parties at enactment, and the enactor supplies the `witness` without being trusted to evaluate it.

#### 3.4 Holding representation while locked

A registry representing holdings on-ledger MUST, while a lock is active, represent the locked funds as the `Holding`s in `holdingCids`, in `terms.authorizer`, summing to `terms.amount`, with `lock` set on each to:

- `holders`: the named parties of the terms (`LockTerms`, section 2), or the registry admin alone if there are none;
- `expiresAt = Some terms.expiresAt`;
- `expiresAfter = None`;
- `context`: a short human-readable description, e.g. `hashlock to <receiver>` or `vesting, 4 tranches`.

The holding's `meta` MUST carry `splice.lfdecentralizedtrust.org/lock-context` with the same text. `ConditionalLock` MAY be the same contract as the `Holding`, as `LockedAmulet` is, or a separate one referencing it. A registry without on-ledger holdings reports the same through its own view, with `holdingCids` empty.

#### 3.5 Guard evaluation

A rule is enactable when every guard in some alternative's `allOf` is satisfied at enactment, against ledger time, the `witness`, and the acting parties: `actors` plus the approvers recorded for exactly the enacted `ruleId` and `legs` (section 3.3). `Guard_After`, `Guard_Before`, and `Guard_Parties` are as stated on their fields. `Guard_Preimage` is satisfied if some entry of `witness.preimages`, lowercased, is 32 bytes of hex whose digest under `algorithm`, over the decoded bytes rather than the hex text, equals `digest`, so the same preimage satisfies an EVM `sha256(bytes32)` or a Bitcoin `OP_SHA256` lock.

Registries MUST support all guard kinds, at least eight alternatives per rule and eight guards per alternative, and MUST advertise the values they support (section 3.8). Guards are a closed set: no arithmetic, no contract references, no repetition, no nesting beyond `anyOf`/`allOf`.

#### 3.6 Outcome enactment and continuation

On `Enact`, `Outcome_Unlock` returns the remaining amount to the authorizer unlocked and terminates the lock. `Outcome_Release` releases `fixedLegs` plus the supplied `legs` as stated on `Outcome_Release` and `ConditionalLock_Enact.legs`; the lock continues with the remainder, without the fired rule, or terminates when nothing remains. A leg to `terms.authorizer` is an unlock.

`Expire` is as stated on `ConditionalLock_Expire`. Registries MUST NOT fail an `Expire` for reasons attributable to any party other than the authorizer.

Creating a receiver holding is a transfer, so the registry's transfer rules (allow lists, pause status, provider controls) apply and registries MAY fail an enactment on them. Conservation is checked against the terms; registries whose holdings carry fees MAY deliver reduced amounts and MUST report the deduction in the result `meta`.

`Cancel` and `Amend` are authorized and validated as stated on their choices; `Amend` compares `newTerms.amount` with `terms.amount`, not the holding balance, so fee decay stays out of the check, and `newTerms.requestedAt` SHOULD be the amendment's timestamp.

All time comparisons use ledger time and MUST be expressed as bounds on it (`isLedgerTimeLT`, `isLedgerTimeGE`), not by reading it, which caps the delay between preparing and submitting a transaction at one minute (CIP-0062) and would defeat the submission delay of section 3.8. Registries SHOULD accept holdings whose lock has expired as transfer inputs, per the `Holding.lock` doc comment in `splice-api-token-holding-v2`, so `Expire` can be combined with use in one transaction.

#### 3.7 Event reporting

V2 registries MUST report every holdings change these choices cause through `EventLog_HoldingsChange` (CIP-0112 "EventLog for Transaction Parsing"). Creation, approval of an instruction, amendment, expiry, cancellation, and legs to `terms.authorizer` are holdings changes on `terms.authorizer` with no transfer leg. `Approve` is not reported unless the registry recreates the locked holdings, which it then reports the same way. Each enacted leg to another receiver is a holdings change on `terms.authorizer` and one on the receiver, each carrying a `TransferEventsV2.TransferLegSide` with the identifier `<lockId>/<ruleId>/<legId>` and the leg's `meta`.

A leg's two sides MUST share an identifier, and distinct legs MUST have distinct ones, as CIP-0112 requires, here including legs of different enactments of one lock; `lockId`, `Rule.id`, and `Leg.legId` MUST be non-empty and MUST NOT contain `/`. The registry issues `lockId` at instruction (section 3.2); it MUST be distinct per lock and MUST remain stable across approvals, continuations, and amendments. The three components suffice because a rule id fires at most once per `lockId` and leg ids are unique within an enactment.

`TransferLegSide.meta` MUST contain every key of `Leg.meta`. `Leg.meta` MUST NOT set `splice.lfdecentralizedtrust.org/tx-kind`, `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`, or any other reserved key under `splice.lfdecentralizedtrust.org/conditional-lock/`, and registries MUST reject such terms at creation and amendment. `splice.lfdecentralizedtrust.org/reason` on a leg is not reserved and labels the leg for wallets.

Choice-result and holding `meta` MUST carry `splice.lfdecentralizedtrust.org/tx-kind`: `lock` for creation, approval of an instruction, `Approve`, and amendment; `transfer` for enactments creating receiver holdings; `unlock` for unlocks, cancellation, and expiry. A holding's `meta` is fixed at creation, so a continuation's backing holding carries `lock` even when its enactment reports `transfer`. Enactment results MUST carry `splice.lfdecentralizedtrust.org/conditional-lock/rule-id`. `splice.lfdecentralizedtrust.org/reason` SHOULD be set on reject, withdraw, cancel, expire, and amend.

#### 3.8 Registry limits and off-ledger API

Registries implementing the package MUST advertise `splice-api-token-conditional-lock-v1` in `supportedApis` of `GET /registry/metadata/v1/instruments/{instrumentId}`, and MUST advertise their limits in the factory `meta`:

- `splice.lfdecentralizedtrust.org/conditional-lock/max-rules` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-legs` (legs released by one enactment, `length fixedLegs + length ConditionalLock_Enact.legs`; MUST be at least 8; also bounds `Outcome_Release.receivers`);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-alternatives-per-rule` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-guards-per-alternative` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-preimages` (MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-named-parties` (distinct named parties of the terms, which the registry carries as lock holders; MUST be at least 8);
- `splice.lfdecentralizedtrust.org/conditional-lock/max-duration` (ISO-8601; MUST be at least 30 days);
- `splice.lfdecentralizedtrust.org/conditional-lock/min-duration` (ISO-8601; SHOULD reflect the registry's submission delay, see Security Considerations; for Canton Coin at least 24 hours per CIP-0107).

Registries MUST serve the following endpoints, each returning the choice context and disclosed contracts for the named choice:

- `POST /registry/conditional-lock/v1/lock-factory`: `ConditionalLockFactory_Lock`, with the factory contract id, shaped like the CIP-0056 transfer-factory endpoint;
- `POST /registry/conditional-lock/v1/{lockInstructionId}/choice-contexts/{accept|reject|withdraw}`: the choice on a `ConditionalLockInstruction`;
- `POST /registry/conditional-lock/v1/{lockContractId}/choice-contexts/{enact|approve|expire|cancel|amend}`: the choice on a `ConditionalLock`, addressed by its contract id rather than by `ConditionalLockView.lockId`.

#### 3.9 View budget

Transaction cost grows with the number of views, one per called choice whose informees the caller lacks (CIP-0112 "Guidelines & Interfaces for Performance Optimization"). Registries MUST implement the nine `*ExtraObservers` functions of section 3, each setting its choice's observers, and SHOULD do so such that each choice generates a single view. An `ExtraObservers` function is evaluated before the choice body; it MUST be total and MUST NOT fail.

The `ConditionalLock` and `ConditionalLockInstruction_Accept` functions are as stated on their doc comments, including the empty list for a `ruleId` not in `terms.rules` on `Enact` and `Approve`. `ConditionalLockFactory_Lock` usually returns the parties of `terms.authorizer` and of every account whose approval the registry expects in the same transaction; `ConditionalLockInstruction_Reject` and `_Withdraw` those of `terms.authorizer` and of the accounts still in `pendingApprovals`.

Registries whose instruments do not require confidentiality between a lock's stakeholders MAY set all named parties as choice observers on every choice, per CIP-0112's recommendation for such assets; registries that do require confidentiality MUST NOT, and `conditionalLock_enactExtraObservers` bounds who learns a revealed preimage as stated on it. The intended budget is one view per exercised choice; the escrowed DvP of section 4 exercises two `ConditionalLock_Enact` choices in one transaction and SHOULD therefore cost at most three views. These functions bound visibility, not authorization: naming a party never entitles it to enact a rule.

### 4. Worked terms

Written in shorthand: accounts are shown as their owning party, a rule's single alternative as its `allOf`, and `Leg` without its `meta`, empty throughout.

- **HTLC leg.** One rule: enactors `[bob]`, `allOf [Guard_Preimage Sha256 H]`, outcome `Outcome_Release with fixedLegs = [Leg "claim" bob amount]; receivers = []`.
- **Escrowed DvP with a dispute window.** Alice locks X for Bob, with `deadline < expiresAt`. Rule `settle`: enactors `[alice, bob]`, `allOf [Guard_Parties [alice, bob] 2, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "delivery" bob amount]; receivers = []`. Rule `award`: enactors `[arbiter]`, `allOf [Guard_After deadline, Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [alice, bob]`. Bob's lock of Y on registry B is symmetric; both `settle` rules are enacted jointly in one Canton transaction. `settle` applies before the deadline, `award` at most once from the deadline to expiry, and after expiry `Expire` returns the remainder to Alice. In the venue form, the venue is `settle`'s only enactor, its guards unchanged, and Alice and Bob each approve `settle` on both locks from their own wallets. This trades counterparty risk for trust in the venue, a named party of both locks, needed for `Cancel` and `Amend`, and able to enact one lock without the other.
- **Arbiter escrow.** One rule: enactors `[arbiter]`, `allOf [Guard_Parties [arbiter] 1]`, outcome `Outcome_Release with fixedLegs = []; receivers = [buyer, seller]`. The arbiter can award all to one side or split.
- **Vesting.** Four rules, each with enactors `[grantee]`, `allOf [Guard_After T_k]`, and outcome `Outcome_Release with fixedLegs = [Leg "tranche-k" grantee (amount/4)]; receivers = []`. The lock continues with the remainder after each.
- **Collateral.** Rule `repaid`: enactors `[pledgee]`, `allOf [Guard_Parties [pledgee] 1]`, outcome `Outcome_Unlock`. Rule `default`, enactable between maturity and expiry (`maturity < expiresAt`): enactors `[pledgee]`, `allOf [Guard_After maturity, Guard_Parties [pledgee] 1]`, outcome `Outcome_Release with fixedLegs = [Leg "default" pledgee amount]; receivers = []`. Margin top-up and maturity extension go through `Amend`, which may reuse the unfired `default` id.
- **Conditional payment.** One rule, with `deadline <= expiresAt`: enactors `[payee]`, `allOf [Guard_Parties [attestor] 1, Guard_Before deadline]`, outcome `Outcome_Release with fixedLegs = [Leg "payment" payee amount]; receivers = []`. The attestor approves the rule from their own wallet with `ConditionalLock_Approve`, and the payee enacts later, alone.

## Rationale

**A release policy rather than an HTLC.** Escrow, vesting, collateral, and conditional payment are an HTLC with different guards and more than one outcome, so one data model covers them all.

**A closed guard set with a fixed two-level shape.** A rule is a disjunction (`anyOf`) of conjunctions (`allOf`) of leaf guards, so wallets render a two-level list; registries advertise limits above mandatory floors, as CIP-0112 sets a floor of 25 transfer legs per allocation.

**Partial consumption instead of nested terms.** A rule fires once and the lock continues with the remainder, so vesting is a flat rule list rather than a tree of successor terms.

**Atomicity instead of cross-lock guards.** Two locks enacted in one transaction commit or fail together, so a guard on another lock's state adds nothing.

**Expiry always unlocks.** A directed outcome on expiry is an ordinary `Guard_After` rule naming the beneficiary, with `expiresAt` as the safety valve behind it; in CIP-0112, expiry, withdrawal, and cancellation only return funds to the authorizer.

**One release outcome.** `Outcome_Release` carries fixed legs and a bounded discretionary part under one conservation check, as CIP-0112 allocations do, so a fixed fee plus a discretionary award is one rule; the enactor may release the fixed legs alone (Security Considerations, "Enactor discretion").

**A new package rather than a change to `splice-api-token-holding-v2`.** Adding choices to `Holding` would break every implementation. A separate package follows the CIP-0112 evolution model: registries opt in, wallets discover support through `supportedApis`, and the on-ledger footprint is the existing `Lock` view.

**Why not an allocation with metadata.** The draft locking CIP (cips#250) carries governance locks as V2 allocations with namespaced metadata and judges that cheaper than a dedicated interface; that holds for a lock released by a party decision on one registry. Fact-checked releases, several outcomes over one pool, and a receiver bound on discretion would, as metadata, become a guard language each registry enforces its own way: the cross-registry HTLC gap this CIP closes.

**What a registry must implement.** Three interfaces and the section 3.4 holding representation, the `Lock` view of CIP-0056, built at CIP-0112's Daml-LF target. Every guard kind and outcome is mandatory; only the section 3.8 limits vary. Guard evaluation, terms validation, and outcome resolution are pure functions of the terms, witness, acting parties, and ledger time; the reference implementation provides them as one module a registry reuses around its nine choice bodies.

**Approvals.** Creating a receiver holding requires the receiver's authority, as for transfers, and a registry MAY also require the account's provider. `ConditionalLock_Approve` records approvals on the lock, so a `Guard_Parties` quorum is reached one party at a time from their own wallets, as in cips#250, without a registry delegation contract; an approval binds the exact legs, so it cannot be reused for another split.

**Byte-domain hashing.** External-chain hashlocks hash bytes, so guards use `DA.Crypto.Text.sha256` and `keccak256` on decoded hex, not `DA.Text.sha256` on UTF-8 text. Both algorithms are mandatory: SHA-256 for Bitcoin, Lightning, and EVM HTLCs, Keccak-256 for EVM-native counterparties.

**Canton Coin.** `LockedAmulet` carries only `holders`, `expiresAt`, and a context, so a Canton Coin implementation is a sibling template carrying the terms, with the factory on `ExternalPartyAmuletRules` so externally signed parties can act within the CIP-0107 submission delay. `TransferConfig.maxNumLockHolders` is the bound `max-named-parties` advertises. CIP-0078 charges no holding fee on transfer inputs, so enactment conserves the locked amount. Abandoned locks need an admin `Expire` returning funds to the authorizer (Security Considerations, "Expired locks"); `LockedAmulet_ExpireAmuletV2` burns expired dust instead. cips#250 puts the CIP-0105 (aggregate per Super Validator) and CIP-0116 (per PartyId) governance locks on V2 allocations, without expiry, vesting continuously, with owner substitution; this CIP does not replace them, and both reach wallets through `Holding.lock`.

**Alternatives considered.**

- Application-owned escrow templates: funds leave the authorizer's portfolio, changing tax and custody treatment.
- `TransferPreapproval` with off-ledger coordination: no on-ledger enforcement of condition or expiry.
- Registry-specific locks such as `LockedAmulet`: one registry only, not condition-aware.
- Cross-lock and oracle-data guards: unnecessary given atomic enactment and `Guard_Parties`; deferred.

## Backwards Compatibility

The CIP is additive: no existing package, interface, choice, or endpoint changes, and registries that do not implement it are unaffected. Wallets that do not implement it display conditionally locked holdings as locked and fall back to CIP-0056's generic rendering for choices outside the standard (`lock` is a new value of Splice's `tx-kind` metadata key). Applications test for the package per instrument through `supportedApis`.

## Reference Implementation

An Apache-2.0 reference implementation is at https://github.com/tankcdr/conditional-holding-lock: this package, an implementation over the published `TestTokenV2` package, the OpenAPI file `conditional-lock-v1.yaml`, and Daml Script property proofs, including byte-domain hash vectors shared with EVM and Solana reference programs. Adding the package to Splice's `token-standard` directory, extending `TestTokenV2` there, wallet support, and a Canton Coin implementation await the maintainers' schedule and are required before this CIP can move to Final.

## Security Considerations

- **Timelock ordering.** In a two-chain swap the leg released first by the preimage must have the shorter expiry, leaving the party who learns it on-ledger time to claim on the other chain.
- **Blocked receivers.** Enactment is a transfer: a paused or blocked receiver fails the rule and the funds return to the authorizer at expiry, while the other chain's leg stays claimable. Counterparties SHOULD confirm receiver status before funding the external leg, and registries SHOULD surface it through the choice-context endpoint (section 3.8).
- **Submission delay.** A registry's delay between preparation and execution (up to 24 hours on Canton Coin under CIP-0107) shrinks the enactment window. Wallets MUST allow for it when choosing `expiresAt` and `Guard_Before`, and registries SHOULD publish `min-duration` accordingly.
- **Authoring errors.** A rule whose `fixedLegs` exceed the remaining amount cannot fire. Wallets SHOULD check that every firing sequence stays enactable, and registries MAY reject terms whose legs exceed `amount`.
- **Enactor discretion.** With non-empty `receivers` the enactor chooses amounts within the receiver set and the remainder net of `fixedLegs`; authorizers SHOULD gate it with `Guard_Parties`. Supplied legs MAY be empty, so the enactor can take `fixedLegs` alone and leave the rest to expire; authorizers SHOULD size fixed fees with that in mind.
- **Recorded approvals.** Once recorded approvals for a rule and legs meet its `Guard_Parties` and include an enactor, any party able to exercise `ConditionalLock_Enact` can trigger exactly that enactment, the other guards still checked. An approval cannot depend on another lock and is irrevocable until `Amend` clears it, so a party SHOULD NOT approve its outgoing leg of a multi-lock settlement while a counterparty who is an enactor can complete the quorum; section 4 gives the venue form. Each `Approve` replaces the lock and can contend with an in-flight enactment; one list of legs per approver per rule, each `Approve` recording someone new, bounds this. Approved legs a continuation leaves unfunded, or that approvers list in different orders, stay approved until an `Amend`; wallets SHOULD supply legs in a canonical order.
- **Expired locks.** An expired lock can only be expired or cancelled, and registries MUST NOT fire any rule after expiry. Registries MAY let the admin alone `Expire` a lock or `Withdraw` an abandoned instruction at or after `expiresAt`, since funds only return to the authorizer, and registries whose holdings accrue fees MUST provide that cleanup path.
- **Preimages.** The lock's signatories hash and compare the witness (section 3.3), so the enactor cannot make a guard appear satisfied. A revealed preimage is visible to the enactment's stakeholders and the choice observers of section 3.9. A digest reused across locks is a wallet error, and wallets SHOULD warn.
- **Privacy.** Digests, receivers, named parties, and `Lock.context` are visible to the lock's stakeholders and, through `context`, to account providers. Wallets SHOULD keep `context` generic.
- **Authorization.** The authorizer's authority is granted at creation and never required at enactment. Implementations MUST check every choice's `actors` (section 3) and MUST ensure no other path moves locked funds.

## Changelog

2026-09-10 - Initial draft.

2026-09-18 - Review round two, resolving the review comments on the previous revision of `ConditionalLockV1.daml` in canton-network/splice#7294, cited by their line in that revision: flattened `Guard` into a leaf type with `Alternative.allOf` and `Rule.anyOf` (line 47), renamed `owner` to `authorizer` (line 91), removed the fallback outcome so `Expire` returns the remainder to the authorizer (line 102), merged the release outcomes into `Outcome_Release` with `fixedLegs` and enactor-supplied legs bounded by `receivers` (line 250), added `Leg.legId` and `Leg.meta` (line 61), generalized acceptance to an approver `Account` with `pendingApprovals` and `availableActions` (line 194), reworded guard evaluation as a check by the lock's signatories (line 23), fixed `Amend` semantics, specified the eight `*ExtraObservers` functions, added `lockId`, `enactedRuleIds`, and `holdingCids`, and added `authorizerHoldingCids` to `ConditionalLockResult_Failed`.

2026-09-22 - Rationale: guard evaluation is a registry-neutral pure function a registry reuses rather than implements; what a Canton Coin implementation adds.

2026-09-23 - Accuracy: CIP-0112 section and field citations, the Canton Coin paragraph against CIP-0078 and the `LockedAmulet` choices, CIP-0105's aggregate basis, and the V1 wallet caveat. Time comparisons MUST be bounds on ledger time (section 3.6). Relation to the draft locking CIP, cips#250, in Motivation and Rationale.

2026-09-23 - Round three: recorded approvals (`ConditionalLock_Approve`, `ConditionalLockView.approvals`) so `Guard_Parties` quorums can be reached one party at a time.

2026-09-24 - Tightened, no normative change.

## Copyright

This CIP is licensed under CC0-1.0: [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). Code in the reference implementation is licensed under Apache-2.0.
