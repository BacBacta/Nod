import { createPublicClient, createWalletClient, defineChain, http, isAddress, isHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";
import { createKeeper } from "./keeper";

const env = z
  .object({
    RPC_URL: z.string().url(),
    CHAIN_ID: z.coerce.number(),
    REGISTRY_ADDRESS: z.string().refine(isAddress),
    REGISTRY_FROM_BLOCK: z.coerce.bigint().default(0n),
    // Operational key holding KEEPER_ROLE on the Registry (no other privilege).
    KEEPER_PRIVATE_KEY: z.string().refine((v) => isHex(v) && v.length === 66),
    INTERVAL_SECONDS: z.coerce.number().default(3600),
    ORACLE_CARDINALITY: z.coerce.number().default(100),
    MIN_TOKEN_FEES: z.coerce.bigint().default(1n),
    MAX_SPLITS: z.coerce.number().default(4),
    LOG_CHUNK_BLOCKS: z.coerce.bigint().default(50_000n),
    ONCE: z.enum(["true", "false"]).default("false"),
  })
  .parse(process.env);

const chain = defineChain({
  id: env.CHAIN_ID, name: `chain-${env.CHAIN_ID}`,
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [env.RPC_URL] } },
});
const transport = http(env.RPC_URL);
const pub = createPublicClient({ chain, transport });
const wallet = createWalletClient({ chain, transport, account: privateKeyToAccount(env.KEEPER_PRIVATE_KEY as Hex) });

const keeper = createKeeper(pub, wallet, {
  registry: env.REGISTRY_ADDRESS as Address,
  fromBlock: env.REGISTRY_FROM_BLOCK,
  oracleCardinality: env.ORACLE_CARDINALITY,
  minTokenFees: env.MIN_TOKEN_FEES,
  maxSplits: env.MAX_SPLITS,
  logChunk: env.LOG_CHUNK_BLOCKS,
});

console.log(`Nod keeper ${wallet.account.address} on chain ${env.CHAIN_ID}, registry ${env.REGISTRY_ADDRESS}`);
for (;;) {
  try {
    await keeper.runOnce();
  } catch (err) {
    console.error(`[keeper] run failed: ${(err as Error).message}`);
  }
  if (env.ONCE === "true") break;
  await new Promise((r) => setTimeout(r, env.INTERVAL_SECONDS * 1000));
}
