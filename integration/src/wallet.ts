// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Validator/wallet API client. Amulet routes settlement through allocations
// (see PROVEN-PAYLOADS.md step 7): both the sender and the receiver must
// allocate before SettlementFactory_SettleBatch can find every authorization
// it needs, so both wallet-facing endpoints below are exercised by the DvP.

async function request(method: string, url: string, bearer: string, body?: unknown) {
  const headers: Record<string, string> = { "content-type": "application/json" };
  headers.authorization = `Bearer ${bearer}`;
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${method} ${url} -> ${res.status}\n${text.slice(0, 4000)}`);
  }
  return text ? JSON.parse(text) : {};
}

export interface UserStatus {
  party_id: string;
  user_onboarded: boolean;
  user_wallet_installed: boolean;
}

export async function userStatus(validatorBase: string, bearer: string): Promise<UserStatus> {
  return request("GET", `${validatorBase}/v0/wallet/user-status`, bearer);
}

export async function tap(validatorBase: string, bearer: string, amount: string): Promise<void> {
  await request("POST", `${validatorBase}/v0/wallet/tap`, bearer, { amount });
}

export interface Balance {
  round: number;
  effective_unlocked_qty: string;
  effective_locked_qty: string;
  total_holding_fees: string;
}

export async function balance(validatorBase: string, bearer: string): Promise<Balance> {
  return request("GET", `${validatorBase}/v0/wallet/balance`, bearer);
}

export interface TransferLegSide {
  transfer_leg_id: string;
  side: "SENDERSIDE" | "RECEIVERSIDE";
  otherside: string;
  amount: string;
}

export interface AllocateV2Request {
  settlement: {
    executors: string[];
    settlement_ref: { id: string };
    settlement_deadline: number;
  };
  committed: boolean;
  transfer_leg_sides: TransferLegSide[];
}

export interface AllocateV2Response {
  output: { allocation_cid: string };
  sender_change_cids: string[];
  meta: unknown;
}

export async function allocateV2(
  validatorBase: string,
  bearer: string,
  req: AllocateV2Request,
): Promise<AllocateV2Response> {
  return request("POST", `${validatorBase}/v2/allocations`, bearer, req);
}

export async function withdrawAllocationV2(
  validatorBase: string,
  bearer: string,
  allocationCid: string,
): Promise<{ authorizer_holding_cids: Record<string, string[]> }> {
  return request("POST", `${validatorBase}/v2/allocations/${allocationCid}/withdraw`, bearer, {});
}

export async function listAllocations(validatorBase: string, bearer: string): Promise<unknown[]> {
  const r = await request("GET", `${validatorBase}/v0/allocations`, bearer);
  return r.allocations as unknown[];
}
