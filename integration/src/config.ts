// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, "..", "..");

/** Plain-text `KEY=value` line lookup; never write this file back. */
function readEnvFile(file: string): Map<string, string> {
  const values = new Map<string, string>();
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return values;
  }
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || !trimmed.includes("=")) continue;
    const idx = trimmed.indexOf("=");
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim().replace(/^["']|["']$/g, "");
    values.set(key, value);
  }
  return values;
}

const dotEnvLocalnet = readEnvFile(path.join(ROOT, ".env.localnet"));

const providerJsonApi =
  process.env.LEDGER_JSON_API ?? dotEnvLocalnet.get("LEDGER_JSON_API") ?? "http://localhost:3975";

const imageTag = process.env.IMAGE_TAG ?? dotEnvLocalnet.get("IMAGE_TAG");
if (!imageTag) {
  throw new Error(
    "No IMAGE_TAG found (checked $IMAGE_TAG and .env.localnet). The Splice image tag is " +
      "recorded into the evidence as splice_image_tag and must never be guessed. " +
      "Fix .env.localnet with ./scripts/localnet-sync.sh.",
  );
}

// scripts/lib/localnet_endpoints.py is the one derivation of every localnet
// endpoint from the app-provider JSON Ledger API URL; spawn it the same way
// token.ts spawns localnet_token.py rather than re-deriving ports here.
const ENDPOINTS_SCRIPT = path.join(ROOT, "scripts", "lib", "localnet_endpoints.py");

function deriveEndpoints(providerUrl: string): {
  user_json_api: string;
  provider_validator: string;
  user_validator: string;
  scan: string;
} {
  let stdout: string;
  try {
    stdout = execFileSync("python3", [ENDPOINTS_SCRIPT, "--ledger-json-api", providerUrl], {
      encoding: "utf8",
    });
  } catch (err) {
    const e = err as { status?: number; stderr?: string | Buffer };
    throw new Error(
      `localnet_endpoints.py --ledger-json-api ${providerUrl} failed (exit ${e.status ?? "?"}): ` +
        `${(e.stderr ?? "").toString().trim()}`,
    );
  }
  return JSON.parse(stdout);
}

// Only spawn the derivation if at least one endpoint is not already overridden
// by an environment variable, so a fully-overridden config never depends on
// LEDGER_JSON_API conforming to the <node><suffix> port pattern.
const needsDerivation =
  !process.env.APP_USER_JSON_API ||
  !process.env.PROVIDER_VALIDATOR ||
  !process.env.USER_VALIDATOR ||
  !process.env.SCAN_API;
const derived = needsDerivation ? deriveEndpoints(providerJsonApi) : undefined;

export const config = {
  imageTag,
  providerJsonApi,
  userJsonApi: process.env.APP_USER_JSON_API ?? derived!.user_json_api,
  providerValidator: process.env.PROVIDER_VALIDATOR ?? derived!.provider_validator,
  userValidator: process.env.USER_VALIDATOR ?? derived!.user_validator,
  scan: process.env.SCAN_API ?? derived!.scan,
};
