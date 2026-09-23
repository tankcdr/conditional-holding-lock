// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// DvP: a TestTokenV2 delivery leg locked by conditional-lock-test-token,
// settled atomically against a real Amulet payment leg. Payload shapes trace
// to packages/conditional-lock-test-token/daml/ConditionalLock/TestToken.daml,
// packages/splice-api-token-conditional-lock-v1/daml/Splice/Api/Token/ConditionalLockV1.daml,
// and Splice 0.8.0's token-standard/splice-api-token-allocation-v2 and
// apps/wallet/src/main/openapi/wallet-internal.yaml.
import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { config, ROOT } from "../src/config.js";
import * as ledger from "../src/ledger.js";
import * as scenario from "../src/scenario.js";
import { token } from "../src/token.js";
import { allocateV2, balance, withdrawAllocationV2 } from "../src/wallet.js";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, Math.max(ms, 0)));
}

// Accumulated across both describe blocks; written once, in afterAll, only if
// both sections filled in (afterAll also runs on failure, and "after a
// successful run" means never writing a partial file).
const record: any = { parties: {}, packages_observed: {} };

// Once per suite run, so the evidence gate can tell two runs' artifacts apart
// even if their contract IDs happened to collide (they won't, but the field
// exists so "which run produced this file" is never a guess).
const runNonce = randomUUID();

// TokenRules created per run, archived in afterAll regardless of pass/fail so
// they do not accumulate on the ledger run over run.
const tokenRulesToArchive: Array<{ registry: string; rulesCid: string }> = [];

function recordPackage(ev: { packageName: string; templateId: string }): void {
  if (!record.packages_observed[ev.packageName]) {
    record.packages_observed[ev.packageName] = ev.templateId.split(":")[0];
  }
}

describe("settlement: delivery leg vs Amulet payment leg", () => {
  const deliveryAmount = "100.0000000000";
  const paymentAmount = "42.0000000000";
  let parties: scenario.Parties;
  let lockId: string;
  let paymentLegId: string;
  let deliveryLegId: string;
  let mint: scenario.MintResult;
  let locked: scenario.LockedResult;
  let allocations: scenario.AllocationPair;
  let settled: scenario.SettleResult;
  let balanceBefore: Awaited<ReturnType<typeof balance>>;
  let balanceAfter: Awaited<ReturnType<typeof balance>>;

  beforeAll(async () => {
    const observed = await ledger.version(config.providerJsonApi);
    record.canton_version_observed = observed.version;
    record.splice_image_tag = config.imageTag;

    parties = await scenario.resolveParties();
    record.parties = {
      alice: parties.alice,
      bob: parties.bob,
      executor: parties.executor,
      registry_admin: parties.registry,
    };

    lockId = `dvp-${randomUUID().slice(0, 8)}`;
    paymentLegId = `${lockId}/payment`;
    deliveryLegId = `${lockId}/settle/delivery`; // <lockId>/<ruleId>/<legId>, see ConditionalLock/TestToken.daml enact

    mint = await scenario.mintTestTokenHolding(parties.registry, parties.alice, deliveryAmount);
    tokenRulesToArchive.push({ registry: parties.registry, rulesCid: mint.rulesCid });

    const now = new Date();
    const deadline = new Date(now.getTime() + 10 * 60 * 1000);
    const expiresAt = new Date(deadline.getTime() + 5 * 60 * 1000);
    const terms = scenario.buildLockTerms({
      alice: parties.alice,
      bob: parties.bob,
      executor: parties.executor,
      instrument: mint.instrument,
      amount: deliveryAmount,
      deadline,
      expiresAt,
      context: "DvP delivery leg",
    });

    locked = await scenario.createAndAcceptLock(parties, lockId, mint.rulesCid, mint.holdingCid, terms);

    await scenario.ensureBobHasAmulet(Number(paymentAmount));

    const aliceTok = await token("alice-wallet");
    balanceBefore = await balance(config.providerValidator, aliceTok);

    const settlementDeadlineUs = Math.floor((now.getTime() + 20 * 60 * 1000) * 1000);
    allocations = await scenario.allocateBothSides({
      parties,
      lockId,
      legId: paymentLegId,
      amount: paymentAmount,
      settlementDeadlineUs,
    });

    // settleAndEnact is the most fragile step: it depends on scan's choice
    // context and disclosed contracts. If it throws, both allocations above
    // stay live and bob's real Amulet stays locked with nothing else able to
    // release it, so withdraw both before the error propagates.
    try {
      settled = await scenario.settleAndEnact({
        parties,
        lockId,
        legId: paymentLegId,
        amount: paymentAmount,
        lockCid: locked.lockCid,
        allocations,
      });
    } catch (err) {
      const [bobTok, aliceTokForWithdraw] = await Promise.all([token("bob-wallet"), token("alice-wallet")]);
      const failures = await scenario.withdrawAllocations([
        { validatorBase: config.userValidator, bearer: bobTok, cid: allocations.senderCid },
        { validatorBase: config.providerValidator, bearer: aliceTokForWithdraw, cid: allocations.receiverCid },
      ]);
      if (failures.length > 0) {
        throw new Error(
          `${(err as Error).message}\nUn-withdrawn allocation(s), a human must act: ${failures.join(", ")}`,
          { cause: err },
        );
      }
      throw err;
    }

    balanceAfter = await balance(config.providerValidator, aliceTok);

    // A second, independent read of the settlement update straight from the
    // participant, for the evidence gate to cross-check claimed fields
    // against. Raw text, not JSON.parse'd and re-stringified.
    record.settlementUpdateRaw = await ledger.updateByIdRaw(
      config.providerJsonApi,
      await token("provider-admin"),
      settled.tx.updateId,
      parties.executor,
    );
  });

  it("is Pending until bob accepts, then an ActiveLock exists", () => {
    const lockCreated = ledger.createdEvents(locked.lockTx);
    expect(lockCreated.some((c) => c.templateId.endsWith(":Instruction"))).toBe(true);
    expect(lockCreated.some((c) => c.templateId.endsWith(":ActiveLock"))).toBe(false);

    const lockExercise = ledger
      .exercisedEvents(locked.lockTx)
      .find((e) => e.choice === "ConditionalLockFactory_Lock");
    // Bob's account is a fixed-leg receiver, so the factory's own result says
    // Pending, not Enacted; observed once live and pinned here rather than
    // just checking truthiness.
    expect(lockExercise?.exerciseResult?.output?.tag).toBe("ConditionalLockResult_Pending");

    const acceptCreated = ledger.createdEvents(locked.acceptTx);
    expect(acceptCreated.some((c) => c.templateId.endsWith(":ActiveLock"))).toBe(true);
  });

  it("settles a TestTokenV2 delivery leg and a real Amulet payment leg in one transaction", async () => {
    const tx = settled.tx;

    // One updateId from one submission with two commands, proven from the
    // ledger's own response (root-node count), not from what we sent.
    expect(ledger.rootCommandCount(tx)).toBe(2);

    const exercised = ledger.exercisedEvents(tx);
    const settleBatch = exercised.find((e) => e.choice === "SettlementFactory_SettleBatch");
    expect(settleBatch?.packageName).toBe("splice-amulet");
    const enact = exercised.find((e) => e.choice === "ConditionalLock_Enact");
    expect(enact?.packageName).toBe("conditional-lock-test-token");

    const created = ledger.createdEvents(tx);
    const amuletCreate = created.find(
      (c) => c.packageName === "splice-amulet" && c.templateId.includes(":Splice.Amulet:Amulet"),
    );
    expect(amuletCreate).toBeDefined();
    expect(amuletCreate!.createArgument.owner).toBe(parties.alice);
    expect(amuletCreate!.createArgument.amount.initialAmount).toBe(paymentAmount);

    const tokenCreate = created.find(
      (c) => c.packageName === "splice-test-token-v2" && c.templateId.includes(".Holding:Token"),
    );
    expect(tokenCreate).toBeDefined();
    expect(tokenCreate!.createArgument.holding.account.owner).toBe(parties.bob);
    expect(tokenCreate!.createArgument.holding.amount).toBe(deliveryAmount);

    // Bob's new holding carries the registry's tx-kind metadata (CIP-0112
    // section 3.7) via the EventLog_HoldingsChange exercises for the delivery
    // transfer leg: both a SenderSide and a ReceiverSide must appear.
    const holdingsChanges = exercised.filter(
      (e) => e.choice === "EventLog_HoldingsChange" && e.packageName === "conditional-lock-test-token",
    );
    const deliverySides = holdingsChanges
      .flatMap((e) => e.choiceArgument.transferLegSides as Array<{ transferLegId: string; side: string }>)
      .filter((s) => s.transferLegId === deliveryLegId);
    expect(deliverySides.some((s) => s.side === "SenderSide")).toBe(true);
    expect(deliverySides.some((s) => s.side === "ReceiverSide")).toBe(true);

    // Amulet balances drift with holding fees, and the wallet's balance view
    // updates asynchronously after submit-and-wait returns at commit, so the
    // created contract's amount above is the assertion; these are a record.
    console.log(
      `alice wallet balance: ${balanceBefore.effective_unlocked_qty} -> ${balanceAfter.effective_unlocked_qty}`,
    );

    const archived = exercised.filter((e) => e.choice === "Archive" && e.consuming);
    expect(archived.some((e) => e.contractId === locked.lockCid)).toBe(true);
    expect(archived.some((e) => e.templateId.endsWith(":LockedHolding"))).toBe(true);

    // The delivery leg is checked in both directions above; the payment leg
    // must be too, or an alice-to-alice self-transfer would pass every
    // assertion above it. The settle-batch's own echoed choiceArgument names
    // bob as sender and alice as receiver of the payment leg.
    const paymentLeg = settleBatch!.choiceArgument.transferLegs[0];
    expect(paymentLeg.sender).toEqual(scenario.account(parties.bob));
    expect(paymentLeg.receiver).toEqual(scenario.account(parties.alice));

    // And an Amulet-side contract owned by bob must be archived in this same
    // update: the LockedAmulet that backed his allocation. An ExercisedEvent's
    // Archive carries no createArgument, so its owner is confirmed by reading
    // the contract's create event back from bob's own participant.
    const lockedAmuletArchive = archived.find((e) => e.templateId.endsWith(":Splice.Amulet:LockedAmulet"));
    expect(lockedAmuletArchive).toBeDefined();
    const bobTok = await token("bob-wallet");
    const lockedAmuletEvents = await ledger.eventsByContractId(
      config.userJsonApi,
      bobTok,
      lockedAmuletArchive!.contractId,
      parties.bob,
    );
    expect(lockedAmuletEvents.created?.createdEvent.createArgument.amulet.owner).toBe(parties.bob);
    expect(lockedAmuletEvents.created?.createdEvent.createArgument.amulet.amount.initialAmount).toBe(paymentAmount);

    for (const e of created) recordPackage(e);
    for (const e of exercised) recordPackage(e);

    record.synchronizer_id = tx.synchronizerId;
    const choicesOfInterest = ["SettlementFactory_SettleBatch", "Allocation_Settle", "ConditionalLock_Enact"];
    // lock_id, the delivery transfer leg id, and the payment instrument id all
    // come off the settle-batch's own echoed choiceArgument/transferLegSides,
    // not the values this test happened to send.
    record.settlement = {
      lock_id: settleBatch!.choiceArgument.settlement.id,
      update_id: tx.updateId,
      effective_at: tx.effectiveAt,
      command_count: ledger.rootCommandCount(tx),
      delivery: {
        instrument_id: tokenCreate!.createArgument.holding.instrumentId.id,
        amount: tokenCreate!.createArgument.holding.amount,
        package_name: tokenCreate!.packageName,
        holding_contract_id: tokenCreate!.contractId,
        receiver: tokenCreate!.createArgument.holding.account.owner,
      },
      payment: {
        instrument_id: settleBatch!.choiceArgument.transferLegs[0].instrumentId,
        amount: amuletCreate!.createArgument.amount.initialAmount,
        package_name: amuletCreate!.packageName,
        holding_contract_id: amuletCreate!.contractId,
        receiver: amuletCreate!.createArgument.owner,
        sender: paymentLeg.sender.owner,
      },
      transfer_leg_ids: [deliverySides[0]!.transferLegId],
      amulet_allocation_cids: [allocations.senderCid, allocations.receiverCid],
      lock_contract_id: locked.lockCid,
      choices_exercised: [...new Set(exercised.map((e) => e.choice))].filter((c) => choicesOfInterest.includes(c)),
    };
  });
});

describe("expiry: the deadline passes before the counterparty acts", () => {
  it(
    "returns the locked TestTokenV2 to the seller when the deadline passes",
    async () => {
      const parties = await scenario.resolveParties();
      const lockId = `dvp-expiry-${randomUUID().slice(0, 8)}`;
      const amount = "100.0000000000";
      const paymentAmount = "7.0000000000";
      const legId = `${lockId}/payment`;

      const mint = await scenario.mintTestTokenHolding(parties.registry, parties.alice, amount);
      tokenRulesToArchive.push({ registry: parties.registry, rulesCid: mint.rulesCid });

      const now = new Date();
      const deadline = new Date(now.getTime() + 25_000);
      const expiresAt = new Date(now.getTime() + 40_000);
      const terms = scenario.buildLockTerms({
        alice: parties.alice,
        bob: parties.bob,
        executor: parties.executor,
        instrument: mint.instrument,
        amount,
        deadline,
        expiresAt,
        context: "DvP delivery leg that expires",
      });

      const locked = await scenario.createAndAcceptLock(parties, lockId, mint.rulesCid, mint.holdingCid, terms);

      // lock_id and the terms' deadline/expiresAt read off the ledger's own
      // echo of what it accepted, not the values this test happened to send.
      const factoryCreate = ledger.createdEvents(locked.factoryTx).find((c) => c.templateId.endsWith(":Factory"))!;
      const lockExercise = ledger
        .exercisedEvents(locked.lockTx)
        .find((e) => e.choice === "ConditionalLockFactory_Lock")!;
      const echoedTerms = lockExercise.choiceArgument.terms;

      await scenario.ensureBobHasAmulet(Number(paymentAmount));
      const bobTok = await token("bob-wallet");
      const settlement = {
        executors: [parties.executor],
        settlement_ref: { id: lockId },
        settlement_deadline: Math.floor(expiresAt.getTime() * 1000),
      };
      const alloc = await allocateV2(config.userValidator, bobTok, {
        settlement,
        committed: false,
        transfer_leg_sides: [
          { transfer_leg_id: legId, side: "SENDERSIDE", otherside: parties.alice, amount: paymentAmount },
        ],
      });
      const allocationCid = alloc.output.allocation_cid;

      // From here on, bob's real Amulet is locked into this allocation. If
      // anything below throws, withdraw it before the error propagates
      // rather than stranding it (the happy path below withdraws it too, via
      // its own explicit call once expiry has actually happened).
      let allocationWithdrawn = false;
      try {
        await sleep(deadline.getTime() - Date.now() + 3_000);

        let rejection = "";
        let rejectedAt = "";
        try {
          await scenario.attemptEnact(parties, locked.lockCid);
          throw new Error("ConditionalLock_Enact succeeded after the deadline; that is a bug");
        } catch (err) {
          // The JSON API's error body carries no ledger timestamp for a
          // rejected submission; wall clock at the moment of observation is
          // the honest value here.
          rejectedAt = scenario.iso(new Date());
          rejection = (err as Error).message;
        }
        expect(rejection).toContain("no alternative is satisfied");

        await sleep(expiresAt.getTime() - Date.now() + 3_000);

        const expireTx = await scenario.expireLock(parties, locked.lockCid);
        const returned = ledger
          .createdEvents(expireTx)
          .find((c) => c.templateId.endsWith(":Token") && c.createArgument.holding.account.owner === parties.alice);
        expect(returned).toBeDefined();
        expect(returned!.createArgument.holding.amount).toBe(amount);
        expect(returned!.createArgument.holding.lock).toBeNull();

        // A second, independent read of the expiry update, for the evidence
        // gate to cross-check claimed fields against.
        record.expireUpdateRaw = await ledger.updateByIdRaw(
          config.providerJsonApi,
          await token("provider-admin"),
          expireTx.updateId,
          parties.alice,
        );

        const withdrawal = await withdrawAllocationV2(config.userValidator, bobTok, allocationCid);
        allocationWithdrawn = true;
        expect((withdrawal.authorizer_holding_cids.Amulet ?? []).length).toBeGreaterThan(0);

        record.expiry = {
          lock_id: factoryCreate.createArgument.lockId,
          deadline: echoedTerms.rules[0].anyOf[0].allOf[1].value.time,
          expires_at: echoedTerms.expiresAt,
          enact_rejected_at: rejectedAt,
          enact_rejection: "no alternative is satisfied",
          expire_update_id: expireTx.updateId,
          returned_contract_id: returned!.contractId,
          returned_amount: returned!.createArgument.holding.amount,
          amulet_allocation_withdrawn_cid: allocationCid,
        };
      } catch (err) {
        const failures = allocationWithdrawn
          ? []
          : await scenario.withdrawAllocations([
              { validatorBase: config.userValidator, bearer: bobTok, cid: allocationCid },
            ]);
        if (failures.length > 0) {
          throw new Error(
            `${(err as Error).message}\nUn-withdrawn allocation(s), a human must act: ${failures.join(", ")}`,
            { cause: err },
          );
        }
        throw err;
      }
    },
    90_000,
  );
});

afterAll(async () => {
  // Archive every run's TokenRules regardless of pass/fail (afterAll also
  // runs on failure), so they do not accumulate on the ledger run over run.
  // Best-effort: a cleanup failure here must not mask a test failure above it.
  for (const { registry, rulesCid } of tokenRulesToArchive) {
    try {
      await scenario.archiveTokenRules(registry, rulesCid);
    } catch (err) {
      console.error(`could not archive TokenRules ${rulesCid}: ${(err as Error).message}`);
    }
  }

  if (!record.settlement || !record.expiry) return; // partial: a prior test failed, write nothing
  const ordered = {
    canton_version_observed: record.canton_version_observed,
    splice_image_tag: record.splice_image_tag,
    synchronizer_id: record.synchronizer_id,
    parties: record.parties,
    packages_observed: record.packages_observed,
    settlement: record.settlement,
    expiry: record.expiry,
    run_nonce: runNonce,
    recorded_at: new Date().toISOString(),
  };
  const dir = path.join(ROOT, "integration", ".run");
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, "dvp-run.json"), JSON.stringify(ordered, null, 2) + "\n", "utf8");
  // The evidence gate's second, independent reads of the two updates, written
  // verbatim (not re-serialized) so they are the participant's own bytes.
  await writeFile(path.join(dir, "settlement-update.json"), record.settlementUpdateRaw, "utf8");
  await writeFile(path.join(dir, "expire-update.json"), record.expireUpdateRaw, "utf8");
});
