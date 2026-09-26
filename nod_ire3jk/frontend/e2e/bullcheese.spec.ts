import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";

// Pull-model launchpad (Bullcheese) on the local stack: DevLocal seeds DEMO2 ("BULL"),
// whose LP locker belongs to anvil #1 and holds 200 USDC of creator fees.
const deployments = JSON.parse(readFileSync(new URL("../src/deployments/31337.json", import.meta.url), "utf8"));
const CREATOR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

async function confirm(page: Page, label: string) {
  await expect(page.getByRole("status").filter({ hasText: `${label} : confirmé` })).toBeVisible({ timeout: 30_000 });
}

test("creator hands the Bullcheese locker to Nod, registers, then collects the fees", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Compte anvil #1 (local)" }).click();
  await page.getByRole("button", { name: "Enregistrer un token" }).click();

  await page.getByLabel("Adresse du token").fill(deployments.bullcheeseDemoToken);
  await page.getByRole("button", { name: "Bullcheese" }).click();
  await page.getByLabel("Identifiant du compte (numérique, jamais le pseudo)").fill("12345");
  await page.getByLabel("Bénéficiaire 1").fill(CREATOR);

  // Registration is blocked until the locker is handed to the predicted vault.
  await expect(page.getByText("Transférez d'abord le verrou")).toBeVisible();
  await page.getByRole("button", { name: "Transférer le verrou au vault" }).click();
  await confirm(page, "Transférer le verrou");
  await expect(page.getByText("Transfert du verrou en attente d'acceptation par le vault.")).toBeVisible();

  await page.getByRole("button", { name: "Enregistrer", exact: true }).click();
  // Registered: the app switches to the token view.
  await expect(page.locator("h2")).toContainText("En attente", { timeout: 30_000 });

  await page.getByRole("button", { name: "Accepter le token" }).click();
  await confirm(page, "Accepter le token");
  await page.getByRole("button", { name: "Accepter ma part" }).click();
  await confirm(page, "Accepter la part #0");

  await page.getByRole("button", { name: "Collecter les frais du launchpad" }).click();
  await confirm(page, "Collecter les frais du launchpad");
  // 200 USDC collected from the locker, minus the 10% protocol fee.
  await expect(page.locator("tbody tr").nth(0)).toContainText("180 USDC");
});
