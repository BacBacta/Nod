import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  createPublicClient, createWalletClient, encodeAbiParameters, http, keccak256, stringToBytes,
  type Address, type Hex,
} from "viem";
import { anvil } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { registryAbi } from "../../frontend/src/abi/Registry";
import { feeVaultFactoryAbi } from "../../frontend/src/abi/FeeVaultFactory";
import { createKeeper } from "../src/keeper";

// Needs a freshly seeded local stack (scripts/dev-local.sh) at NOD_ANVIL_RPC. Skipped otherwise.
const rpc = process.env.NOD_ANVIL_RPC;
const d = JSON.parse(readFileSync(new URL("../../frontend/src/deployments/31337.json", import.meta.url), "utf8"));

// Anvil default keys: public, local only.
const CREATOR = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"); // #1
const KEEPER = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");  // #5

const lockerAbi = [
  { type: "function", name: "transferOwnership", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { type: "function", name: "accrue", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
] as const;
const erc20 = [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }] as const;

describe.skipIf(!rpc || !d.bullcheeseLocker)("keeper on the local stack", () => {
  const transport = http(rpc);
  // viem polls receipts every 4s by default; a missed first check then costs 4s per tx.
  const pollingInterval = 100;
  const pub = createPublicClient({ chain: anvil, transport, pollingInterval });
  const creator = createWalletClient({ chain: anvil, transport, account: CREATOR, pollingInterval });
  const config = { registry: d.registry as Address, fromBlock: 0n, oracleCardinality: 50, minTokenFees: 1n, maxSplits: 4, logChunk: 10_000n };

  async function tx(hash: Hex) {
    expect((await pub.waitForTransactionReceipt({ hash })).status).toBe("success");
  }

  it("collects Bullcheese fees and converts token fees to USDC", async () => {
    const token = d.bullcheeseDemoToken as Address;
    const [vault] = await pub.readContract({ address: d.factory, abi: feeVaultFactoryAbi, functionName: "predictVaultAddress", args: [CREATOR.address, token] });
    const creatorId = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "string" }], [keccak256(stringToBytes("x")), "12345"]));

    await tx(await creator.writeContract({ address: d.bullcheeseLocker, abi: lockerAbi, functionName: "transferOwnership", args: [vault] }));
    await tx(await creator.writeContract({
      address: d.registry, abi: registryAbi, functionName: "registerToken",
      args: [token, d.bullcheeseAdapter, creatorId, [{ recipient: CREATOR.address, bps: 10_000 }], d.fallback, keccak256(stringToBytes("bullcheese"))],
    }));
    // 200 USDC already waiting in the locker (DevLocal) + 1,000 USDC-worth of token fees.
    await tx(await creator.writeContract({ address: d.bullcheeseLocker, abi: lockerAbi, functionName: "accrue", args: [0n, 1_000_000_000n] }));

    const logs: string[] = [];
    const keeper = createKeeper(pub, createWalletClient({ chain: anvil, transport, account: KEEPER, pollingInterval }), config, (m) => logs.push(m));
    const [report] = await keeper.runOnce();

    expect(report.token).toBe(token);
    expect(report.collected).toBe(true);
    expect(report.swaps.reduce((s, x) => s + x.amountIn, 0n)).toBe(1_000_000_000n);
    expect(await pub.readContract({ address: token, abi: erc20, functionName: "balanceOf", args: [vault] })).toBe(0n);
    expect(await pub.readContract({ address: d.usdc, abi: erc20, functionName: "balanceOf", args: [vault] })).toBe(1_200_000_000n);

    // Nothing left: the next run collects but swaps nothing.
    const [again] = await keeper.runOnce();
    expect(again.swaps).toHaveLength(0);
  });

  it("splits a swap that moves the price too much, and stops at the TWAP floor", async () => {
    // The mock router pays 1:1 at TWAP; make it pay 5% less (e.g. a thin pool).
    const routerAbi = [{ type: "function", name: "setRateBps", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] }] as const;
    const router = await pub.readContract({ address: d.registry, abi: registryAbi, functionName: "swapRouter" });
    const deployer = createWalletClient({ chain: anvil, transport, pollingInterval, account: privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") });
    await tx(await deployer.writeContract({ address: router, abi: routerAbi, functionName: "setRateBps", args: [9_500n] }));
    await tx(await creator.writeContract({ address: d.bullcheeseLocker, abi: lockerAbi, functionName: "accrue", args: [0n, 8_000_000n] }));

    const keeper = createKeeper(pub, createWalletClient({ chain: anvil, transport, account: KEEPER, pollingInterval }), config, () => {});
    const [report] = await keeper.runOnce();
    expect(report.swaps).toHaveLength(0);
    expect(report.note).toMatch(/below the TWAP floor/);

    await tx(await deployer.writeContract({ address: router, abi: routerAbi, functionName: "setRateBps", args: [10_000n] }));
    const [ok] = await keeper.runOnce();
    expect(ok.swaps.reduce((s, x) => s + x.amountIn, 0n)).toBe(8_000_000n);
  });

  it("a key without KEEPER_ROLE cannot convert", async () => {
    await creator.writeContract({ address: d.bullcheeseLocker, abi: lockerAbi, functionName: "accrue", args: [0n, 5_000_000n] })
      .then((h) => pub.waitForTransactionReceipt({ hash: h }));
    const keeper = createKeeper(pub, creator, config, () => {});
    const [report] = await keeper.runOnce();
    expect(report.swaps).toHaveLength(0);
    expect(report.note).toMatch(/AccessControlUnauthorizedAccount/);
  });
});
