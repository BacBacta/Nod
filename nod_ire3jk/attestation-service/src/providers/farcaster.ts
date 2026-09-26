import { createAppClient, viemConnector } from "@farcaster/auth-client";
import type { VerifiedIdentity } from "../identity";

/** Sign In With Farcaster: proves control of a FID (custody or approved auth address). */
export interface FarcasterVerifier {
  verify(p: { message: string; signature: `0x${string}`; nonce: string; domain: string }): Promise<VerifiedIdentity>;
}

/** Checks the SIWF signature against the FID's keys in the Farcaster registries (Optimism). */
export function farcasterVerifier(optimismRpcUrl?: string): FarcasterVerifier {
  const client = createAppClient({ ethereum: viemConnector(optimismRpcUrl ? { rpcUrl: optimismRpcUrl } : undefined) });
  return {
    async verify({ message, signature, nonce, domain }) {
      const res = await client.verifySignInMessage({ message, signature, nonce, domain });
      if (res.isError || !res.success) {
        throw new Error(`Farcaster sign-in invalid: ${res.error?.message ?? "verification failed"}`);
      }
      return { platform: "farcaster", externalId: String(res.fid) };
    },
  };
}
