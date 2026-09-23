// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// The single source of truth for "which package ids are ours" is
// scripts/lib/dar_identity.py (also used by scripts/localnet-bootstrap.sh);
// this spawns it rather than re-deriving package ids from DAR manifests here.
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { ROOT } from "./config.js";

const execFileAsync = promisify(execFile);

/** Package name -> main package id, for the first-party packages attached to a release. */
export async function firstPartyPackageIds(): Promise<Record<string, string>> {
  const libDir = path.join(ROOT, "scripts", "lib");
  const script = [
    "import sys, json",
    `sys.path.insert(0, ${JSON.stringify(libDir)})`,
    "import dar_identity",
    "out = {}",
    "for p, attached in dar_identity.PACKAGES:",
    "    if not attached:",
    "        continue",
    "    built = dar_identity.built_dar_path(p)",
    "    if not built.exists():",
    "        continue",
    "    out[p] = dar_identity.main_package_id(built)",
    "print(json.dumps(out))",
  ].join("\n");
  const { stdout } = await execFileAsync("python3", ["-c", script]);
  return JSON.parse(stdout);
}
