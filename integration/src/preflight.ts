// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// vitest globalSetup: fail fast and clearly before spending 60+ seconds in the
// expiry test if the localnet is down or missing the DARs this suite depends
// on, rather than surfacing that as an inscrutable fetch/ledger error deep in
// a test.
import { rm } from "node:fs/promises";
import path from "node:path";
import { config, ROOT } from "./config.js";
import { listPackageIds, participantId } from "./ledger.js";
import { token } from "./token.js";
import { firstPartyPackageIds } from "./darIdentity.js";

export default async function globalSetup(): Promise<void> {
  // A failing run must not strand the *previous* successful run's artifact:
  // delete it up front so a failed run leaves integration/.run/ empty rather
  // than stale.
  await rm(path.join(ROOT, "integration", ".run"), { recursive: true, force: true });

  let versionBody: { version: string };
  try {
    const res = await fetch(`${config.providerJsonApi}/v2/version`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    versionBody = (await res.json()) as { version: string };
  } catch {
    throw new Error(
      `The Mainnet-configuration localnet is not running at ${config.providerJsonApi}.\n` +
        `Start it with:  ./scripts/localnet.sh`,
    );
  }

  if (!versionBody.version.startsWith("3.5.")) {
    throw new Error(
      `Expected Canton 3.5.x on the app-provider participant, observed ${versionBody.version}. ` +
        `This suite is pinned to the Mainnet-configuration localnet; re-sync it with ./scripts/localnet-sync.sh.`,
    );
  }

  const expected = await firstPartyPackageIds();
  const expectedNames = Object.keys(expected);
  if (expectedNames.length === 0) {
    throw new Error(
      "No first-party DARs are built (scripts/lib/dar_identity.py found none under packages/*/.daml/dist). " +
        "Build and upload them with: ./scripts/localnet-bootstrap.sh",
    );
  }

  const providerAdmin = await token("provider-admin");
  const appUserLedger = await token("app-user-ledger");
  const [providerIds, appUserIds, providerParticipantId, appUserParticipantId] = await Promise.all([
    listPackageIds(config.providerJsonApi, providerAdmin),
    listPackageIds(config.userJsonApi, appUserLedger),
    participantId(config.providerJsonApi, providerAdmin),
    participantId(config.userJsonApi, appUserLedger),
  ]);

  const missing = (participant: string, ids: string[]) =>
    expectedNames.filter((name) => !ids.includes(expected[name])).map((name) => `${participant}: ${name}`);

  const allMissing = [...missing("app-provider", providerIds), ...missing("app-user", appUserIds)];
  if (allMissing.length > 0) {
    throw new Error(
      `First-party DARs are missing from a participant:\n  ${allMissing.join("\n  ")}\n` +
        `Fix it with: ./scripts/localnet-bootstrap.sh`,
    );
  }

  // The two nodes' HS256 tokens are interchangeable (same user, audience, and
  // secret), so pointing config.providerJsonApi and config.userJsonApi at the
  // same port would otherwise pass every check above while only ever proving
  // one participant. The harness needs the receiver on a second participant
  // because that is the whole point of the cross-participant lock.
  if (providerParticipantId === appUserParticipantId) {
    throw new Error(
      `config.providerJsonApi (${config.providerJsonApi}) and config.userJsonApi (${config.userJsonApi}) ` +
        `resolve to the same participant (${providerParticipantId}). The harness needs the receiver on a ` +
        `second participant because that is the whole point of the cross-participant lock.`,
    );
  }
}
