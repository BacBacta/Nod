import { defineConfig } from "vitest/config";

// Integration tests send several transactions to a local chain: allow for slow CI runners.
export default defineConfig({ test: { testTimeout: 30_000 } });
