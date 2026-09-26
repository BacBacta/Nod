import { defineConfig } from "@playwright/test";

// Requires a running local stack (scripts/dev-local.sh) and `npm run dev`.
export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  use: {
    baseURL: process.env.NOD_URL ?? "http://127.0.0.1:5173",
    launchOptions: process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {},
  },
});
