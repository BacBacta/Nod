import { test, expect, type Page } from "@playwright/test";

// Uses the local attestation service (scripts/dev-attestation.sh) with simulated OAuth.

async function connect(page: Page, n: 1 | 2) {
  await page.getByRole("button", { name: `Compte anvil #${n} (local)` }).click();
  await expect(page.getByRole("button", { name: "Déconnecter" })).toBeVisible();
}

async function verifyWith(page: Page, platform: string, accountId: string) {
  await page.getByRole("button", { name: "Vérifier mon identité" }).click();
  await page.getByRole("button", { name: `Continuer avec ${platform}` }).click();
  // Simulated provider consent page (DEV_FAKE_OAUTH), then back to the app.
  await expect(page.getByRole("heading", { name: /Connexion simulée/ })).toBeVisible();
  await page.getByLabel("Identifiant du compte").fill(accountId);
  await page.getByRole("button", { name: "Autoriser" }).click();
  await expect(page.getByText(accountId, { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Enregistrer l'attestation" }).click();
}

test("a new creator links a GitHub account to their wallet", async ({ page }) => {
  await page.goto("/");
  await connect(page, 2);
  await verifyWith(page, "GitHub", "777");
  await expect(page.getByRole("status").filter({ hasText: "Identité liée" })).toContainText("0x3C44…93BC", { timeout: 30_000 });
});

test("an identity that already has a wallet goes through the 7-day rotation", async ({ page }) => {
  await page.goto("/");
  await connect(page, 2);
  // X account 12345 is the demo creator, already linked to anvil #1.
  await verifyWith(page, "X", "12345");
  const status = page.getByRole("status").filter({ hasText: "Changement de wallet demandé" });
  await expect(status).toContainText("0x3C44…93BC remplacera 0x7099…79C8", { timeout: 30_000 });

  // Too early: the button stays disabled until the 7-day delay has passed.
  const finish = page.getByRole("button", { name: "Finaliser le changement de wallet" });
  await expect(finish).toBeDisabled();
  for (const method of ["evm_increaseTime", "evm_mine"]) {
    await fetch("http://127.0.0.1:8545", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: method === "evm_mine" ? [] : [7 * 86_400 + 1] }),
    });
  }
  await expect(finish).toBeEnabled({ timeout: 30_000 });
  await finish.click();
  await expect(page.getByRole("status").filter({ hasText: "Finaliser le changement de wallet : confirmé" })).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText("Aucun changement de wallet en attente pour cette identité.")).toBeVisible();
});
