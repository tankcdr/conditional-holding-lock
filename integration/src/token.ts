// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// The one token minter is scripts/lib/localnet_token.py; this module only
// spawns it and hands back stdout. No JWT is ever minted here, and the token
// never appears in argv, in a log line, or in a thrown error.
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { ROOT } from "./config.js";

const execFileAsync = promisify(execFile);
const MINTER = path.join(ROOT, "scripts", "lib", "localnet_token.py");

export type Role = "provider-admin" | "alice-wallet" | "bob-wallet" | "app-user-ledger";

const ROLE_ARGS: Record<Role, readonly string[]> = {
  "provider-admin": ["--node", "app-provider", "--admin"],
  "alice-wallet": ["--node", "app-provider", "--user", "app-provider"],
  "bob-wallet": ["--node", "app-user", "--user", "app-user"],
  "app-user-ledger": ["--node", "app-user"],
};

const cache = new Map<Role, string>();

export async function token(role: Role): Promise<string> {
  const cached = cache.get(role);
  if (cached) return cached;

  const args = ROLE_ARGS[role];
  let stdout: string;
  try {
    ({ stdout } = await execFileAsync("python3", [MINTER, ...args]));
  } catch (err) {
    const e = err as { code?: number; stderr?: string };
    // argv is safe to log (--node/--user/--admin only); stdout never is.
    throw new Error(
      `localnet_token.py ${args.join(" ")} failed (exit ${e.code ?? "?"}): ${(e.stderr ?? "").trim()}`,
    );
  }

  const value = stdout.trim();
  cache.set(role, value);
  return value;
}
