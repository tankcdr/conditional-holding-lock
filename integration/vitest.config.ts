// Copyright (c) 2026 Long Run Advisory. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The expiry test sleeps through a real deadline and a real expiresAt;
    // no fake timers exist against a live Canton ledger.
    testTimeout: 90_000,
    hookTimeout: 60_000,
    globalSetup: ["./src/preflight.ts"],
  },
});
