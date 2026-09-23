// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// JSON Ledger API v2 client. Ledger-effects transaction shape throughout
// (verified against /docs/openapi): that shape is what carries
// createArgument/choiceArgument and packageName on every event, which the
// DvP assertions read.

export interface CreateCommand {
  CreateCommand: { templateId: string; createArguments: unknown };
}
export interface ExerciseCommand {
  ExerciseCommand: { templateId: string; contractId: string; choice: string; choiceArgument: unknown };
}
export type Command = CreateCommand | ExerciseCommand;

export interface DisclosedContract {
  templateId: string;
  contractId: string;
  createdEventBlob: string;
  synchronizerId: string;
}

export interface CreatedEvent {
  nodeId: number;
  contractId: string;
  templateId: string;
  createArgument: any;
  packageName: string;
  representativePackageId: string;
}

export interface ExercisedEvent {
  nodeId: number;
  lastDescendantNodeId: number;
  contractId: string;
  templateId: string;
  choice: string;
  choiceArgument: any;
  exerciseResult: any;
  consuming: boolean;
  packageName: string;
}

export interface Transaction {
  updateId: string;
  commandId: string;
  effectiveAt: string;
  events: Array<{ CreatedEvent?: CreatedEvent } | { ExercisedEvent?: ExercisedEvent }>;
  synchronizerId: string;
}

async function request(method: string, url: string, bearer: string | undefined, body?: unknown) {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    // Status and body only. Never the Authorization header or the token.
    throw new Error(`${method} ${url} -> ${res.status}\n${text.slice(0, 4000)}`);
  }
  return text ? JSON.parse(text) : {};
}

export async function version(base: string): Promise<{ version: string }> {
  return request("GET", `${base}/v2/version`, undefined);
}

export async function listPackageIds(base: string, bearer: string): Promise<string[]> {
  const r = await request("GET", `${base}/v2/packages`, bearer);
  return r.packageIds as string[];
}

/** GET /v2/parties/participant-id -> {"participantId": "..."} (verified against /docs/openapi). */
export async function participantId(base: string, bearer: string): Promise<string> {
  const r = await request("GET", `${base}/v2/parties/participant-id`, bearer);
  return r.participantId as string;
}

/**
 * POST /v2/events/events-by-contract-id -> the create and consuming-archive
 * events for one contract (verified against /docs/openapi). Used to look up
 * fields (e.g. an Amulet's owner) that an ExercisedEvent's Archive carries no
 * createArgument for.
 */
export async function eventsByContractId(
  base: string,
  bearer: string,
  contractId: string,
  party: string,
): Promise<{ created?: { createdEvent: CreatedEvent }; archived?: { archivedEvent: unknown } }> {
  return request("POST", `${base}/v2/events/events-by-contract-id`, bearer, {
    contractId,
    eventFormat: {
      filtersByParty: {
        [party]: { cumulative: [{ identifierFilter: { WildcardFilter: { value: { includeCreatedEventBlob: false } } } }] },
      },
      verbose: false,
    },
  });
}

/**
 * POST /v2/updates/update-by-id, returning the raw response body verbatim
 * (not JSON.parse'd and re-stringified). This is the evidence gate's
 * independent, second read of an update: the gate cross-checks every
 * claimed field against these bytes, so they must be the participant's own
 * bytes with nothing edited.
 *
 * The response wraps the transaction as `update.Transaction.value` (verified
 * against /docs/openapi and against a live update); the deprecated
 * `/v2/updates/transaction-by-id` returns it flat under `transaction`
 * instead. scripts/record-reference-proof.py's `load_update_file` unwraps
 * either shape.
 */
export async function updateByIdRaw(base: string, bearer: string, updateId: string, party: string): Promise<string> {
  const body = {
    updateId,
    updateFormat: {
      includeTransactions: {
        transactionShape: "TRANSACTION_SHAPE_LEDGER_EFFECTS",
        eventFormat: {
          filtersByParty: {
            [party]: {
              cumulative: [{ identifierFilter: { WildcardFilter: { value: { includeCreatedEventBlob: true } } } }],
            },
          },
          verbose: false,
        },
      },
    },
  };
  const url = `${base}/v2/updates/update-by-id`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${bearer}` },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`POST ${url} -> ${res.status}\n${text.slice(0, 4000)}`);
  }
  return text;
}

export interface PartyDetails {
  party: string;
  isLocal: boolean;
}

export async function listParties(base: string, bearer: string): Promise<PartyDetails[]> {
  const r = await request("GET", `${base}/v2/parties?pageSize=1000`, bearer);
  return r.partyDetails as PartyDetails[];
}

export async function allocateParty(base: string, bearer: string, hint: string): Promise<string> {
  const r = await request("POST", `${base}/v2/parties`, bearer, {
    partyIdHint: hint,
    identityProviderId: "",
    userId: "ledger-api-user",
  });
  return r.partyDetails.party as string;
}

/** Re-runnable party lookup: the localnet ledger persists, a second allocate with the same hint fails. */
export async function findOrAllocateParty(base: string, bearer: string, hint: string): Promise<string> {
  const existing = await listParties(base, bearer);
  const match = existing.find((d) => d.isLocal && d.party.split("::")[0] === hint);
  if (match) return match.party;
  return allocateParty(base, bearer, hint);
}

export interface SubmitOptions {
  base: string;
  bearer: string;
  actAs: string[];
  readAs?: string[];
  commands: Command[];
  disclosedContracts?: DisclosedContract[];
  userId?: string;
  commandId: string;
}

export async function submitAndWaitForTransaction(opts: SubmitOptions): Promise<{ transaction: Transaction }> {
  const commands: Record<string, unknown> = {
    commandId: opts.commandId,
    commands: opts.commands,
    actAs: opts.actAs,
    readAs: opts.readAs ?? [],
    disclosedContracts: opts.disclosedContracts ?? [],
  };
  if (opts.userId) commands.userId = opts.userId;

  const body = {
    commands,
    transactionFormat: {
      transactionShape: "TRANSACTION_SHAPE_LEDGER_EFFECTS",
      eventFormat: {
        filtersByParty: Object.fromEntries(
          opts.actAs.map((p) => [
            p,
            { cumulative: [{ identifierFilter: { WildcardFilter: { value: { includeCreatedEventBlob: true } } } }] },
          ]),
        ),
        verbose: false,
      },
    },
  };
  return request("POST", `${opts.base}/v2/commands/submit-and-wait-for-transaction`, opts.bearer, body);
}

export function createdEvents(tx: Transaction): CreatedEvent[] {
  return tx.events.flatMap((e) => ("CreatedEvent" in e && e.CreatedEvent ? [e.CreatedEvent] : []));
}

export function exercisedEvents(tx: Transaction): ExercisedEvent[] {
  return tx.events.flatMap((e) => ("ExercisedEvent" in e && e.ExercisedEvent ? [e.ExercisedEvent] : []));
}

/**
 * Count top-level (root) exercises in an update, i.e. one per submitted
 * command. Ledger-effects events arrive in nodeId order; a node nested inside
 * an earlier root's [nodeId, lastDescendantNodeId] range is a side-effect of
 * that command, not a new one. This is how "one submission, two commands"
 * gets proven from the ledger's own response rather than from what we sent.
 */
export function rootCommandCount(tx: Transaction): number {
  let count = 0;
  let boundary = -1;
  for (const e of tx.events) {
    const data = ("ExercisedEvent" in e && e.ExercisedEvent) || ("CreatedEvent" in e && e.CreatedEvent);
    if (!data) continue;
    if (data.nodeId <= boundary) continue;
    count += 1;
    boundary = "lastDescendantNodeId" in data ? data.lastDescendantNodeId : data.nodeId;
  }
  return count;
}
