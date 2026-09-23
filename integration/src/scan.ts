// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Scan's token-standard registry API needs no auth token (Splice 0.8.0's
// token-standard/splice-api-token-allocation-v2); it resolves the settlement
// factory contract and the disclosed contracts the SettlementFactory_SettleBatch
// choice needs, keyed off the choice arguments alone.
import type { DisclosedContract } from "./ledger.js";

export interface SettlementFactoryResponse {
  factoryId: string;
  choiceContext: {
    choiceContextData: unknown;
    disclosedContracts: DisclosedContract[];
  };
}

export async function getSettlementFactory(
  scanBase: string,
  choiceArguments: unknown,
): Promise<SettlementFactoryResponse> {
  const res = await fetch(`${scanBase}/registry/allocation/v2/settlement-factory`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ choiceArguments, excludeDebugFields: true }),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`POST ${scanBase}/registry/allocation/v2/settlement-factory -> ${res.status}\n${text.slice(0, 4000)}`);
  }
  return JSON.parse(text);
}
