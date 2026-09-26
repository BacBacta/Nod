import { verifyMessage, zeroAddress, zeroHash, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createApp, type AppDeps } from "../src/app";
import type { Chain, IdentityState } from "../src/chain";
import { MemorySessionStore } from "../src/sessions";
import { localKeySigner } from "../src/signer";

// Anvil default keys: public, test only.
export const ATTESTER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
export const USER = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
export const OTHER = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
export const ATTESTOR = "0x00000000000000000000000000000000000a7e57" as Address;
export const FRONTEND = "https://app.nod.test";
export const PUBLIC = "https://attest.nod.test";

export function fakeChain(states: Record<string, Partial<IdentityState>> = {}, chainTime = 0): Chain {
  return {
    chainId: 5042002,
    latestTimestamp: async () => chainTime,
    async identityState(id) {
      return { wallet: zeroAddress, platform: zeroHash, revoked: false, ...states[id] };
    },
    verifyWalletSignature: (address, message, signature) => verifyMessage({ address, message, signature }),
  };
}

export function makeApp(over: Partial<AppDeps> = {}) {
  let t = 1_800_000_000_000;
  const deps: AppDeps = {
    store: new MemorySessionStore(() => t),
    chain: fakeChain(),
    signer: localKeySigner(ATTESTER_KEY),
    attestor: ATTESTOR,
    oauth: {},
    publicUrl: PUBLIC,
    frontendUrl: FRONTEND,
    now: () => t,
    ...over,
  };
  return { app: createApp(deps), deps, advance: (ms: number) => { t += ms; } };
}

export async function post(app: ReturnType<typeof createApp>, path: string, body: unknown) {
  const res = await app.request(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return { status: res.status, body: (await res.json()) as any };
}

/** Create a session for USER and prove the wallet. */
export async function verifiedSession(app: ReturnType<typeof createApp>, account = USER) {
  const start = await post(app, "/v1/sessions", { wallet: account.address });
  const signature = await account.signMessage({ message: start.body.message });
  const r = await post(app, `/v1/sessions/${start.body.sessionId}/wallet-signature`, { signature });
  if (r.status !== 200) throw new Error("wallet proof failed");
  return start.body as { sessionId: string; message: string; nonce: string };
}
