import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { createPublicClient, createWalletClient, http, type Abi, type Address, type Hex } from "viem";
import { anvil } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { createApp } from "../src/app";
import { viemChain } from "../src/chain";
import { creatorIdOf } from "../src/identity";
import type { OAuthProvider } from "../src/providers/oauth";
import { MemorySessionStore } from "../src/sessions";
import { localKeySigner } from "../src/signer";
import { ATTESTER_KEY, OTHER, USER, post, verifiedSession } from "./helpers";

// Runs against a local anvil node (NOD_ANVIL_RPC, e.g. http://127.0.0.1:8545) using the
// real IdentityAttestor bytecode from `forge build`. Skipped when the variable is unset.
const rpc = process.env.NOD_ANVIL_RPC;

describe.skipIf(!rpc)("on-chain: IdentityAttestor accepts service attestations", () => {
  const artifact = JSON.parse(
    readFileSync(new URL("../../contracts/out/IdentityAttestor.sol/IdentityAttestor.json", import.meta.url), "utf8"),
  );
  const abi = artifact.abi as Abi;
  const transport = http(rpc);
  const pub = createPublicClient({ chain: anvil, transport });
  const admin = createWalletClient({ chain: anvil, transport, account: privateKeyToAccount(ATTESTER_KEY) });

  async function deploy(): Promise<Address> {
    const hash = await admin.deployContract({
      abi, bytecode: artifact.bytecode.object as Hex,
      args: [admin.account.address, admin.account.address, admin.account.address],
    });
    return (await pub.waitForTransactionReceipt({ hash })).contractAddress!;
  }

  function service(attestor: Address, externalId: string) {
    const github: OAuthProvider = {
      platform: "github",
      authorizeUrl: ({ state }) => `https://github.example/authorize?state=${state}`,
      identify: async () => ({ platform: "github", externalId, handle: "dev" }),
    };
    return createApp({
      store: new MemorySessionStore(), chain: viemChain(rpc!, anvil.id, attestor),
      signer: localKeySigner(ATTESTER_KEY), attestor, oauth: { github },
      publicUrl: "http://attest.local", frontendUrl: "http://app.local",
    });
  }

  async function issue(app: ReturnType<typeof createApp>, account: typeof USER) {
    const { sessionId } = await verifiedSession(app, account);
    const start = await app.request(`/v1/sessions/${sessionId}/oauth/github`);
    const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
    await app.request(`/v1/oauth/github/callback?code=c&state=${state}`);
    return (await post(app, `/v1/sessions/${sessionId}/attestation`, {})).body;
  }

  async function submit(attestor: Address, att: any, account: typeof USER) {
    const user = createWalletClient({ chain: anvil, transport, account });
    const hash = await user.writeContract({ address: attestor, abi, functionName: att.functionName, args: att.args });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    expect(receipt.status).toBe("success");
  }

  it("first attestation links the wallet; a new wallet goes through rotation", async () => {
    const attestor = await deploy();
    const app = service(attestor, "583231");
    const id = creatorIdOf("github", "583231");

    const first = await issue(app, USER);
    expect(first.mode).toBe("attest");
    await submit(attestor, first, USER);
    expect(await pub.readContract({ address: attestor, abi, functionName: "walletOf", args: [id] })).toBe(USER.address);
    expect(await pub.readContract({ address: attestor, abi, functionName: "creatorIdOf", args: [first.args[0], "583231"] })).toBe(id);

    const second = await issue(app, OTHER);
    expect(second.mode).toBe("initiateRotation");
    await submit(attestor, second, OTHER);
    // Still the old wallet until the 7-day delay passes.
    expect(await pub.readContract({ address: attestor, abi, functionName: "walletOf", args: [id] })).toBe(USER.address);
    const rec = (await pub.readContract({ address: attestor, abi, functionName: "attestations", args: [id] })) as readonly unknown[];
    expect(rec[1]).toBe(OTHER.address);
  });
});
