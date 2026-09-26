import {
  BaseError, ContractFunctionRevertedError, zeroAddress,
  type Address, type Chain, type PublicClient, type WalletClient, type Account, type Transport,
} from "viem";
import { erc20Abi, registryAbi, vaultAbi } from "./abi";

export type KeeperConfig = {
  registry: Address;
  /** Block the Registry was deployed at: token discovery starts here. */
  fromBlock: bigint;
  /** Cardinality asked of each token/USDC pool so a 10-minute TWAP exists. */
  oracleCardinality: number;
  /** Token fees below this raw amount are left for a later run. */
  minTokenFees: bigint;
  /** Halvings tried when a swap fails the TWAP floor (price impact too high). */
  maxSplits: number;
  /** Max blocks per eth_getLogs request. */
  logChunk: bigint;
};

export type TokenReport = {
  token: Address;
  vault: Address;
  collected: boolean;
  swaps: { amountIn: bigint; floor: bigint }[];
  note?: string;
};

type Wallet = WalletClient<Transport, Chain, Account>;

export type Keeper = {
  runOnce(): Promise<TokenReport[]>;
};

/** Short reason for a failed call: the contract error name when there is one. */
export function reason(err: unknown): string {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      // require("...") reverts decode as errorName "Error": prefer the message.
      return revert.reason ?? revert.data?.errorName ?? revert.shortMessage;
    }
    return err.shortMessage;
  }
  return err instanceof Error ? err.message : String(err);
}

export function createKeeper(pub: PublicClient, wallet: Wallet, cfg: KeeperConfig, log = console.log): Keeper {
  const known = new Map<Address, Address>(); // token -> vault (pull-model only)
  const oraclePrepared = new Set<Address>();
  let scannedTo = cfg.fromBlock - 1n;

  async function discover() {
    const latest = await pub.getBlockNumber();
    for (let from = scannedTo + 1n; from <= latest; from += cfg.logChunk) {
      const to = from + cfg.logChunk - 1n < latest ? from + cfg.logChunk - 1n : latest;
      const logs = await pub.getContractEvents({
        address: cfg.registry, abi: registryAbi, eventName: "TokenRegistered", fromBlock: from, toBlock: to,
      });
      for (const l of logs) {
        const { token, vault } = l.args;
        if (!token || !vault) continue;
        const source = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "feeSource" });
        if (source !== zeroAddress) known.set(token, vault);
      }
      scannedTo = to;
    }
  }

  async function send(functionName: "collectFees" | "prepareSwapOracle" | "swapTokenFees", args: readonly unknown[]) {
    const { request } = await pub.simulateContract({
      address: cfg.registry, abi: registryAbi, functionName, args, account: wallet.account,
    } as Parameters<typeof pub.simulateContract>[0]);
    const hash = await wallet.writeContract(request as Parameters<Wallet["writeContract"]>[0]);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${functionName} reverted in ${hash}`);
  }

  async function convert(token: Address, vault: Address, report: TokenReport) {
    let remaining = await pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [vault] });
    let amount = remaining;
    let splits = 0;
    while (remaining >= cfg.minTokenFees && remaining > 0n && amount > 0n) {
      let floor: bigint;
      try {
        [, floor] = await pub.readContract({ address: cfg.registry, abi: registryAbi, functionName: "swapFloor", args: [token, amount] });
      } catch (err) {
        report.note = `no TWAP yet (${reason(err)})`;
        return;
      }
      try {
        // minUsdcOut = the floor: the Registry rejects anything below TWAP - 3%.
        await send("swapTokenFees", [token, amount, floor]);
        report.swaps.push({ amountIn: amount, floor });
        remaining -= amount;
        amount = remaining;
      } catch (err) {
        const why = reason(err);
        // Only the router's slippage check means "too big for the pool": retry smaller.
        if (!/Too little received/i.test(why)) {
          report.note = `swap failed (${why})`;
          return;
        }
        if (++splits > cfg.maxSplits) {
          report.note = `swap below the TWAP floor even at ${amount} (${why})`;
          return;
        }
        amount /= 2n; // price impact too high for this size: try a smaller chunk
      }
    }
  }

  return {
    async runOnce() {
      await discover();
      const reports: TokenReport[] = [];
      for (const [token, vault] of known) {
        const report: TokenReport = { token, vault, collected: false, swaps: [] };
        try {
          await send("collectFees", [token]);
          report.collected = true;
        } catch (err) {
          report.note = `collect failed (${reason(err)})`;
        }
        if (!oraclePrepared.has(token)) {
          try {
            await send("prepareSwapOracle", [token, cfg.oracleCardinality]);
            oraclePrepared.add(token);
          } catch (err) {
            log(`[keeper] ${token}: prepareSwapOracle failed (${reason(err)})`);
          }
        }
        await convert(token, vault, report);
        log(`[keeper] ${token}: collected=${report.collected} swaps=${report.swaps.length}${report.note ? ` (${report.note})` : ""}`);
        reports.push(report);
      }
      return reports;
    },
  };
}
