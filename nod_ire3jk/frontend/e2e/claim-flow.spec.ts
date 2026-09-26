import { test, expect, type Page } from "@playwright/test";

// Full flow on the seeded demo token (dev-local.sh): 1,000 USDC in the vault,
// splits 60% creator (anvil #1) / 40% recipient (anvil #2), 10% protocol fee.
// Run against a freshly seeded local stack.

async function connect(page: Page, n: 1 | 2) {
  await page.getByRole("button", { name: `Compte anvil #${n} (local)` }).click();
  await expect(page.getByRole("button", { name: "Déconnecter" })).toBeVisible();
}

async function run(page: Page, name: string) {
  await page.getByRole("button", { name }).first().click();
  await expect(page.getByRole("status")).toContainText("confirmé", { timeout: 30_000 });
}

test("creator accepts, both recipients accept and claim", async ({ page }) => {
  await page.goto("/");
  await connect(page, 1);

  const header = page.locator("header");
  await expect(header).toContainText("100 USDC");
  await expect(page.locator("h2")).toContainText("En attente");

  await run(page, "Accepter le token");
  await expect(page.locator("h2")).toContainText("Accepté");
  // Both splits still PENDING: their shares are held, not redistributed.
  await expect(page.locator("tbody tr").nth(0)).toContainText("600 USDC");
  await expect(page.locator("tbody tr").nth(1)).toContainText("400 USDC");

  await run(page, "Accepter ma part");
  await expect(page.locator("tbody tr").nth(0)).toContainText("540 USDC");
  await run(page, "Réclamer");
  await expect(header).toContainText("640 USDC");

  await page.getByRole("button", { name: "Déconnecter" }).click();
  await connect(page, 2);
  await run(page, "Accepter ma part");
  await run(page, "Réclamer");
  await expect(header).toContainText("460 USDC");
});

test("a wrong action shows the contract's error name", async ({ page }) => {
  await page.goto("/");
  await connect(page, 2);
  await page.getByRole("tab", { name: "Enregistrer un token" }).or(
    page.getByRole("button", { name: "Enregistrer un token" }),
  ).click();
  await page.getByLabel("Adresse du token").fill("0x000000000000000000000000000000000000dEaD");
  await page.getByLabel("Identifiant du créateur (platformUserId)").fill("someone");
  await page.getByLabel("Bénéficiaire 1").fill("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC");
  await page.getByRole("button", { name: "Enregistrer", exact: true }).click();
  // The mock launchpad has no fee recipient for this token, so the adapter rejects it.
  await expect(page.getByRole("alert")).toContainText("AdapterRejected", { timeout: 30_000 });
});
