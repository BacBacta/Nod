import { defineConfig } from "@playwright/test";

// Requires a freshly seeded local stack (scripts/dev-local.sh), the local attestation
// service (scripts/dev-attestation.sh) and the app (`bun run dev`).
export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  // The specs share one local chain: run them in order.
  workers: 1,
  fullyParallel: false,
  use: {
    baseURL: process.env.NOD_URL ?? "http://localhost:5173",
    launchOptions: process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {},
  },
});
