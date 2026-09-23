// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// The DvP scenario as composable steps. Do not invent payload shapes here:
// our own choices and the transfer-leg-id format trace to
// packages/conditional-lock-test-token/daml/ConditionalLock/TestToken.daml
// and packages/splice-api-token-conditional-lock-v1/daml/Splice/Api/Token/ConditionalLockV1.daml;
// the allocation and wallet payloads trace to Splice 0.8.0's
// token-standard/splice-api-token-allocation-v2 and
// apps/wallet/src/main/openapi/wallet-internal.yaml.
import { randomUUID } from "node:crypto";
import { config } from "./config.js";
import {
  createdEvents,
  findOrAllocateParty,
  submitAndWaitForTransaction,
  type Command,
  type DisclosedContract,
  type Transaction,
} from "./ledger.js";
import { getSettlementFactory } from "./scan.js";
import { token } from "./token.js";
import { allocateV2, balance, tap, userStatus, withdrawAllocationV2, type AllocateV2Request } from "./wallet.js";

// Package-name form template ids, per the Daml sources named above.
const CL = "#splice-api-token-conditional-lock-v1:Splice.Api.Token.ConditionalLockV1";
const TT = "#splice-test-token-v2:Splice.Testing.Tokens.TestTokenV2";
const IMPL = "#conditional-lock-test-token:ConditionalLock.TestToken";
const ALLOC = "#splice-api-token-allocation-v2:Splice.Api.Token.AllocationV2";

export const TEMPLATES = {
  conditionalLockFactory: `${CL}:ConditionalLockFactory`,
  conditionalLockInstruction: `${CL}:ConditionalLockInstruction`,
  conditionalLock: `${CL}:ConditionalLock`,
  implFactory: `${IMPL}:Factory`,
  tokenRules: `${TT}:TokenRules`,
  holdingToken: `${TT}.Holding:Token`,
  settlementFactory: `${ALLOC}:SettlementFactory`,
};

export function account(owner: string) {
  return { owner, provider: null, id: "" };
}

export function meta(values: Record<string, string> = {}) {
  return { values };
}

/**
 * `YYYY-MM-DDTHH:MM:SS.ffffffZ` — Canton's JSON API Time encoding wants
 * microsecond precision; Date#toISOString gives only milliseconds, so pad
 * rather than truncate/round, which is what a lenient server would tolerate
 * but this one does not need to.
 */
export function iso(date: Date): string {
  return date.toISOString().replace(/\.(\d{3})Z$/, ".$1000Z");
}

export function freshCommandId(label: string): string {
  return `integration-${label}-${randomUUID()}`;
}

export interface Parties {
  alice: string;
  bob: string;
  registry: string;
  executor: string;
}

export async function resolveParties(): Promise<Parties> {
  const [aliceTok, bobTok, adminTok] = await Promise.all([
    token("alice-wallet"),
    token("bob-wallet"),
    token("provider-admin"),
  ]);
  const [aliceStatus, bobStatus] = await Promise.all([
    userStatus(config.providerValidator, aliceTok),
    userStatus(config.userValidator, bobTok),
  ]);
  // Party hints persist across runs; look up before allocating (see brief's
  // re-runnability requirement) rather than always creating.
  const registry = await findOrAllocateParty(config.providerJsonApi, adminTok, "cl-registry");
  const executor = await findOrAllocateParty(config.providerJsonApi, adminTok, "cl-executor");
  return { alice: aliceStatus.party_id, bob: bobStatus.party_id, registry, executor };
}

export interface MintResult {
  tx: Transaction;
  rulesCid: string;
  holdingCid: string;
  instrument: { admin: string; id: string };
}

/** Fresh TokenRules and a fresh alice holding, every run (the ledger persists). */
export async function mintTestTokenHolding(registry: string, alice: string, amount: string): Promise<MintResult> {
  const adminTok = await token("provider-admin");
  const rulesTx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [registry],
    userId: "ledger-api-user",
    commandId: freshCommandId("token-rules"),
    commands: [
      { CreateCommand: { templateId: TEMPLATES.tokenRules, createArguments: { admin: registry } } },
    ],
  });
  const rulesCid = createdEvents(rulesTx.transaction).find((c) => c.templateId.endsWith(":TokenRules"))!.contractId;

  const instrument = { admin: registry, id: "TTKN" };
  const mintTx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [registry, alice],
    userId: "ledger-api-user",
    commandId: freshCommandId("mint"),
    commands: [
      {
        CreateCommand: {
          templateId: TEMPLATES.holdingToken,
          createArguments: {
            holding: { account: account(alice), instrumentId: instrument, amount, lock: null, meta: meta() },
          },
        },
      },
    ],
  });
  const holdingCid = createdEvents(mintTx.transaction).find((c) => c.templateId.endsWith(":Token"))!.contractId;
  return { tx: mintTx.transaction, rulesCid, holdingCid, instrument };
}

export interface LockTerms {
  authorizer: ReturnType<typeof account>;
  instrumentId: { admin: string; id: string };
  amount: string;
  rules: unknown[];
  expiresAt: string;
  requestedAt: string;
  meta: ReturnType<typeof meta>;
}

export function buildLockTerms(opts: {
  alice: string;
  bob: string;
  executor: string;
  instrument: { admin: string; id: string };
  amount: string;
  deadline: Date;
  expiresAt: Date;
  context: string;
}): LockTerms {
  return {
    authorizer: account(opts.alice),
    instrumentId: opts.instrument,
    amount: opts.amount,
    rules: [
      {
        id: "settle",
        enactors: [opts.executor],
        anyOf: [
          {
            allOf: [
              { tag: "Guard_Parties", value: { parties: [opts.executor], threshold: "1" } },
              { tag: "Guard_Before", value: { time: iso(opts.deadline) } },
            ],
          },
        ],
        outcome: {
          tag: "Outcome_Release",
          value: {
            fixedLegs: [{ legId: "delivery", receiver: account(opts.bob), amount: opts.amount, meta: meta() }],
            receivers: [],
          },
        },
      },
    ],
    expiresAt: iso(opts.expiresAt),
    requestedAt: iso(new Date(Date.now() - 5000)),
    meta: meta({ "splice.lfdecentralizedtrust.org/lock-context": opts.context }),
  };
}

export interface LockedResult {
  factoryTx: Transaction;
  factoryCid: string;
  lockTx: Transaction;
  instructionCid: string;
  acceptTx: Transaction;
  lockCid: string;
}

// If a run is aborted between here and ConditionalLock_Enact/ConditionalLock_Expire
// (e.g. the process is killed), the ActiveLock this creates stays live with bob's
// real Amulet allocated against it. That is bounded to one leftover ActiveLock per
// aborted run and is harmless; ./scripts/localnet.sh --clean clears it along with
// everything else on the ledger.
/** Create our Factory, lock (Pending), then bob accepts (ActiveLock). */
export async function createAndAcceptLock(
  parties: Parties,
  lockId: string,
  rulesCid: string,
  holdingCid: string,
  terms: LockTerms,
): Promise<LockedResult> {
  const adminTok = await token("provider-admin");
  const bobTok = await token("bob-wallet");

  const factoryTx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [parties.registry],
    userId: "ledger-api-user",
    commandId: freshCommandId("factory"),
    commands: [
      {
        CreateCommand: {
          templateId: TEMPLATES.implFactory,
          createArguments: { admin: parties.registry, tokenRulesCid: rulesCid, lockId },
        },
      },
    ],
  });
  const factoryCid = createdEvents(factoryTx.transaction).find((c) => c.templateId.endsWith(":Factory"))!.contractId;

  const extraArgs = { context: meta(), meta: meta() };
  const lockTx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [parties.alice],
    readAs: [parties.registry],
    userId: "ledger-api-user",
    commandId: freshCommandId("lock"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.conditionalLockFactory,
          contractId: factoryCid,
          choice: "ConditionalLockFactory_Lock",
          choiceArgument: { terms, inputHoldingCids: [holdingCid], actors: [parties.alice], extraArgs },
        },
      } satisfies Command,
    ],
  });
  const instructionCid = createdEvents(lockTx.transaction).find((c) => c.templateId.endsWith(":Instruction"))!
    .contractId;

  const acceptTx = await submitAndWaitForTransaction({
    base: config.userJsonApi,
    bearer: bobTok,
    actAs: [parties.bob],
    commandId: freshCommandId("accept"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.conditionalLockInstruction,
          contractId: instructionCid,
          choice: "ConditionalLockInstruction_Accept",
          choiceArgument: { approver: account(parties.bob), actors: [parties.bob], extraArgs },
        },
      },
    ],
  });
  const lockCid = createdEvents(acceptTx.transaction).find((c) => c.templateId.endsWith(":ActiveLock"))!.contractId;

  return {
    factoryTx: factoryTx.transaction,
    factoryCid,
    lockTx: lockTx.transaction,
    instructionCid,
    acceptTx: acceptTx.transaction,
    lockCid,
  };
}

/** Tap only if bob's unlocked Amulet would not cover the payment plus margin. */
export async function ensureBobHasAmulet(minAmount: number): Promise<void> {
  const bobTok = await token("bob-wallet");
  const current = await balance(config.userValidator, bobTok);
  if (Number(current.effective_unlocked_qty) < minAmount + 10) {
    await tap(config.userValidator, bobTok, "500.0");
  }
}

export interface AllocationPair {
  senderCid: string;
  receiverCid: string;
  settlement: AllocateV2Request["settlement"];
}

/** Both sides allocate Amulet against byte-identical `settlement` objects (required by the server). */
export async function allocateBothSides(opts: {
  parties: Parties;
  lockId: string;
  legId: string;
  amount: string;
  settlementDeadlineUs: number;
}): Promise<AllocationPair> {
  const [aliceTok, bobTok] = await Promise.all([token("alice-wallet"), token("bob-wallet")]);
  const settlement = {
    executors: [opts.parties.executor],
    settlement_ref: { id: opts.lockId },
    settlement_deadline: opts.settlementDeadlineUs,
  };
  const senderAlloc = await allocateV2(config.userValidator, bobTok, {
    settlement,
    committed: false,
    transfer_leg_sides: [
      { transfer_leg_id: opts.legId, side: "SENDERSIDE", otherside: opts.parties.alice, amount: opts.amount },
    ],
  });
  // If alice's allocation throws, bob's above is already live and real Amulet
  // is already locked into it; withdraw it before the error propagates rather
  // than stranding it (the caller's own try/catch only sees a throw once both
  // allocations exist, so this half of the pair needs its own guard).
  let receiverAlloc: Awaited<ReturnType<typeof allocateV2>>;
  try {
    receiverAlloc = await allocateV2(config.providerValidator, aliceTok, {
      settlement,
      committed: false,
      transfer_leg_sides: [
        { transfer_leg_id: opts.legId, side: "RECEIVERSIDE", otherside: opts.parties.bob, amount: opts.amount },
      ],
    });
  } catch (err) {
    const failures = await withdrawAllocations([
      { validatorBase: config.userValidator, bearer: bobTok, cid: senderAlloc.output.allocation_cid },
    ]);
    if (failures.length > 0) {
      throw new Error(
        `${(err as Error).message}\nUn-withdrawn allocation(s), a human must act: ${failures.join(", ")}`,
        { cause: err },
      );
    }
    throw err;
  }
  return { senderCid: senderAlloc.output.allocation_cid, receiverCid: receiverAlloc.output.allocation_cid, settlement };
}

export interface SettleResult {
  tx: Transaction;
  factoryId: string;
}

/** The one transaction: SettlementFactory_SettleBatch and ConditionalLock_Enact together. */
export async function settleAndEnact(opts: {
  parties: Parties;
  lockId: string;
  legId: string;
  amount: string;
  lockCid: string;
  allocations: AllocationPair;
}): Promise<SettleResult> {
  const adminTok = await token("provider-admin");
  const settleArgs: any = {
    settlement: { executors: [opts.parties.executor], id: opts.lockId, cid: null, meta: meta() },
    transferLegs: [
      {
        transferLegId: opts.legId,
        sender: account(opts.parties.bob),
        receiver: account(opts.parties.alice),
        amount: opts.amount,
        instrumentId: "Amulet",
        meta: meta(),
      },
    ],
    allocations: [
      { allocationCid: opts.allocations.senderCid, extraTransferLegSides: [], nextIterationFunding: null },
      { allocationCid: opts.allocations.receiverCid, extraTransferLegSides: [], nextIterationFunding: null },
    ],
    actors: [opts.parties.executor],
    extraArgs: { context: meta(), meta: meta() },
  };

  const factory = await getSettlementFactory(config.scan, settleArgs);
  settleArgs.extraArgs = { context: factory.choiceContext.choiceContextData, meta: meta() };
  const disclosedContracts: DisclosedContract[] = factory.choiceContext.disclosedContracts.map((d) => ({
    templateId: d.templateId,
    contractId: d.contractId,
    createdEventBlob: d.createdEventBlob,
    synchronizerId: d.synchronizerId,
  }));

  const enactArgs = {
    ruleId: "settle",
    actors: [opts.parties.executor],
    witness: { preimages: [] },
    legs: [],
    extraArgs: { context: meta(), meta: meta() },
  };

  const tx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [opts.parties.executor],
    readAs: [opts.parties.registry, opts.parties.alice, opts.parties.bob],
    userId: "ledger-api-user",
    disclosedContracts,
    commandId: freshCommandId("settle"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.settlementFactory,
          contractId: factory.factoryId,
          choice: "SettlementFactory_SettleBatch",
          choiceArgument: settleArgs,
        },
      },
      {
        ExerciseCommand: {
          templateId: TEMPLATES.conditionalLock,
          contractId: opts.lockCid,
          choice: "ConditionalLock_Enact",
          choiceArgument: enactArgs,
        },
      },
    ],
  });

  return { tx: tx.transaction, factoryId: factory.factoryId };
}

export interface AllocationRef {
  validatorBase: string;
  bearer: string;
  cid: string;
}

/**
 * Withdraw every allocation in `refs`, best-effort: a withdrawal failure never
 * throws here, it is collected and returned so the caller can surface it
 * alongside (not instead of) the original error that made the withdrawal
 * necessary in the first place.
 */
export async function withdrawAllocations(refs: AllocationRef[]): Promise<string[]> {
  const failures: string[] = [];
  for (const ref of refs) {
    try {
      await withdrawAllocationV2(ref.validatorBase, ref.bearer, ref.cid);
    } catch (err) {
      failures.push(`${ref.cid} (${(err as Error).message})`);
    }
  }
  return failures;
}

/** Archive a run's per-run TokenRules once the run is done with it (the ledger persists otherwise). */
export async function archiveTokenRules(registry: string, rulesCid: string): Promise<void> {
  const adminTok = await token("provider-admin");
  await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [registry],
    userId: "ledger-api-user",
    commandId: freshCommandId("archive-token-rules"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.tokenRules,
          contractId: rulesCid,
          choice: "Archive",
          choiceArgument: {},
        },
      },
    ],
  });
}

export async function expireLock(parties: Parties, lockCid: string): Promise<Transaction> {
  const adminTok = await token("provider-admin");
  const extraArgs = { context: meta(), meta: meta() };
  const tx = await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [parties.alice],
    readAs: [parties.registry],
    userId: "ledger-api-user",
    commandId: freshCommandId("expire"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.conditionalLock,
          contractId: lockCid,
          choice: "ConditionalLock_Expire",
          choiceArgument: { actors: [parties.alice], extraArgs },
        },
      },
    ],
  });
  return tx.transaction;
}

export async function attemptEnact(parties: Parties, lockCid: string): Promise<void> {
  const adminTok = await token("provider-admin");
  const extraArgs = { context: meta(), meta: meta() };
  await submitAndWaitForTransaction({
    base: config.providerJsonApi,
    bearer: adminTok,
    actAs: [parties.executor],
    readAs: [parties.registry, parties.alice, parties.bob],
    userId: "ledger-api-user",
    commandId: freshCommandId("enact-attempt"),
    commands: [
      {
        ExerciseCommand: {
          templateId: TEMPLATES.conditionalLock,
          contractId: lockCid,
          choice: "ConditionalLock_Enact",
          choiceArgument: { ruleId: "settle", actors: [parties.executor], witness: { preimages: [] }, legs: [], extraArgs },
        },
      },
    ],
  });
}
