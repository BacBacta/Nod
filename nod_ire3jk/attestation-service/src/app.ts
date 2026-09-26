import { Hono, type Context } from "hono";
import { cors } from "hono/cors";
import { z } from "zod";
import { bytesToHex, getAddress, isAddress, isHex, sha256, zeroAddress, zeroHash, type Address, type Hex } from "viem";
import { base64urlnopad } from "./base64url";
import type { Chain } from "./chain";
import { creatorIdOf, isPlatform, platformTag, type Platform } from "./identity";
import type { FarcasterVerifier } from "./providers/farcaster";
import type { OAuthProvider } from "./providers/oauth";
import type { Session, SessionStore } from "./sessions";
import type { AttestationSigner } from "./signer";

export type AppDeps = {
  store: SessionStore;
  chain: Chain;
  signer: AttestationSigner;
  attestor: Address;
  oauth: Partial<Record<Exclude<Platform, "farcaster">, OAuthProvider>>;
  farcaster?: FarcasterVerifier;
  /** Public base URL of this service, used for OAuth redirect URIs. */
  publicUrl: string;
  /** Frontend origin: CORS allowlist, SIWF domain and post-OAuth redirect target. */
  frontendUrl: string;
  sessionTtlMs?: number;
  attestationTtlSec?: number;
  now?: () => number;
  random?: (bytes: number) => Uint8Array;
};

const SESSION_TTL_MS = 15 * 60_000;
const ATTESTATION_TTL_SEC = 30 * 60;

export function createApp(deps: AppDeps) {
  const now = deps.now ?? Date.now;
  const random = deps.random ?? ((n: number) => crypto.getRandomValues(new Uint8Array(n)));
  const sessionTtl = deps.sessionTtlMs ?? SESSION_TTL_MS;
  const attestationTtl = deps.attestationTtlSec ?? ATTESTATION_TTL_SEC;
  const frontend = new URL(deps.frontendUrl);
  const redirectUri = (p: Platform) => `${deps.publicUrl}/v1/oauth/${p}/callback`;

  const app = new Hono();
  app.use("/v1/*", cors({ origin: frontend.origin, allowMethods: ["GET", "POST"] }));
  app.onError((err, c) => {
    // Never echo upstream bodies or tokens; the message is ours.
    console.error(`[attestation] ${c.req.method} ${c.req.path}: ${err.message}`);
    return c.json({ error: "internal_error" }, 500);
  });

  const fail = (c: Context, status: 400 | 404 | 409, error: string, detail?: string) =>
    c.json({ error, ...(detail ? { detail } : {}) }, status);

  function liveSession(c: Context): Session | Response {
    const s = deps.store.get(c.req.param("id") ?? "");
    if (!s) return fail(c, 404, "session_not_found");
    if (s.used) return fail(c, 409, "session_used");
    return s;
  }

  app.get("/v1/platforms", (c) =>
    c.json({
      platforms: [
        ...Object.keys(deps.oauth).map((p) => ({ id: p, method: "oauth" })),
        ...(deps.farcaster ? [{ id: "farcaster", method: "siwf" }] : []),
      ],
      attester: deps.signer.address,
      chainId: deps.chain.chainId,
      attestor: deps.attestor,
    }),
  );

  // 1. Start: the wallet to link. Returns a challenge the wallet must sign.
  app.post("/v1/sessions", async (c) => {
    const body = z.object({ wallet: z.string().refine(isAddress) }).safeParse(await c.req.json().catch(() => null));
    if (!body.success) return fail(c, 400, "invalid_wallet");
    const wallet = getAddress(body.data.wallet);
    const id = base64urlnopad(random(32));
    const nonce = bytesToHex(random(16)).slice(2);
    const expiresAt = now() + sessionTtl;
    const challenge = [
      `${frontend.host} wants you to link this wallet to your creator identity on Nod.`,
      "",
      `Wallet: ${wallet}`,
      `Chain ID: ${deps.chain.chainId}`,
      `Nonce: ${nonce}`,
      `Expires At: ${new Date(expiresAt).toISOString()}`,
    ].join("\n");
    deps.store.set({ id, wallet, nonce, challenge, walletVerified: false, expiresAt, used: false });
    return c.json({ sessionId: id, message: challenge, nonce, expiresAt });
  });

  app.get("/v1/sessions/:id", (c) => {
    const s = liveSession(c);
    if (s instanceof Response) return s;
    return c.json({
      wallet: s.wallet,
      walletVerified: s.walletVerified,
      identity: s.identity && { ...s.identity, creatorId: creatorIdOf(s.identity.platform, s.identity.externalId) },
      expiresAt: s.expiresAt,
    });
  });

  // 2. Prove control of the wallet.
  app.post("/v1/sessions/:id/wallet-signature", async (c) => {
    const s = liveSession(c);
    if (s instanceof Response) return s;
    const body = z.object({ signature: z.string().refine((v) => isHex(v)) }).safeParse(await c.req.json().catch(() => null));
    if (!body.success) return fail(c, 400, "invalid_signature");
    const ok = await deps.chain.verifyWalletSignature(s.wallet, s.challenge, body.data.signature as Hex);
    if (!ok) return fail(c, 400, "invalid_signature");
    deps.store.set({ ...s, walletVerified: true });
    return c.json({ walletVerified: true });
  });

  // 3a. Prove control of a platform account via OAuth (redirects to the provider).
  app.get("/v1/sessions/:id/oauth/:platform", (c) => {
    const s = liveSession(c);
    if (s instanceof Response) return s;
    const platform = c.req.param("platform");
    const provider = isPlatform(platform) && platform !== "farcaster" ? deps.oauth[platform] : undefined;
    if (!provider) return fail(c, 404, "platform_not_enabled");
    if (!s.walletVerified) return fail(c, 409, "wallet_not_verified");

    const state = base64urlnopad(random(32));
    const codeVerifier = base64urlnopad(random(32));
    const codeChallenge = base64urlnopad(sha256(new TextEncoder().encode(codeVerifier), "bytes"));
    deps.store.set({ ...s, oauth: { platform: provider.platform, state, codeVerifier } });
    return c.redirect(provider.authorizeUrl({ state, redirectUri: redirectUri(provider.platform), codeChallenge }), 302);
  });

  app.get("/v1/oauth/:platform/callback", async (c) => {
    const back = (sessionId: string | undefined, status: string) => {
      const url = new URL(deps.frontendUrl);
      url.searchParams.set("verify", status);
      if (sessionId) url.searchParams.set("session", sessionId);
      return c.redirect(url.toString(), 302);
    };
    const platform = c.req.param("platform");
    const { code, state, error } = c.req.query();
    const s = state ? deps.store.findByOAuthState(state) : undefined;
    if (!s || s.used || !s.oauth || s.oauth.platform !== platform) return back(undefined, "invalid_state");
    const provider = deps.oauth[s.oauth.platform as Exclude<Platform, "farcaster">];
    // The state is single use, whatever happens next.
    const { codeVerifier } = s.oauth;
    deps.store.set({ ...s, oauth: undefined });
    if (error || !code || !provider) return back(s.id, "denied");
    try {
      const identity = await provider.identify({ code, redirectUri: redirectUri(provider.platform), codeVerifier });
      deps.store.set({ ...s, oauth: undefined, identity });
      return back(s.id, "ok");
    } catch (err) {
      console.error(`[attestation] ${platform} identify failed: ${(err as Error).message}`);
      return back(s.id, "provider_error");
    }
  });

  // 3b. Prove control of a Farcaster FID with a Sign In With Farcaster message.
  app.post("/v1/sessions/:id/farcaster", async (c) => {
    const s = liveSession(c);
    if (s instanceof Response) return s;
    if (!deps.farcaster) return fail(c, 404, "platform_not_enabled");
    if (!s.walletVerified) return fail(c, 409, "wallet_not_verified");
    const body = z
      .object({ message: z.string().min(1), signature: z.string().refine((v) => isHex(v)) })
      .safeParse(await c.req.json().catch(() => null));
    if (!body.success) return fail(c, 400, "invalid_request");
    try {
      const identity = await deps.farcaster.verify({
        message: body.data.message,
        signature: body.data.signature as Hex,
        nonce: s.nonce,
        domain: frontend.host,
      });
      deps.store.set({ ...s, identity });
      return c.json({ identity: { ...identity, creatorId: creatorIdOf("farcaster", identity.externalId) } });
    } catch (err) {
      return fail(c, 400, "farcaster_invalid", (err as Error).message);
    }
  });

  // 4. Issue the signed attestation. The user submits it on-chain themselves.
  app.post("/v1/sessions/:id/attestation", async (c) => {
    const s = liveSession(c);
    if (s instanceof Response) return s;
    if (!s.walletVerified) return fail(c, 409, "wallet_not_verified");
    if (!s.identity) return fail(c, 409, "identity_not_verified");

    const { platform, externalId } = s.identity;
    const tag = platformTag(platform);
    const creatorId = creatorIdOf(platform, externalId);
    const onchain = await deps.chain.identityState(creatorId);
    if (onchain.revoked) return fail(c, 409, "identity_revoked");
    if (onchain.platform !== zeroHash && onchain.platform !== tag) return fail(c, 409, "platform_mismatch");

    // A new wallet for an existing identity goes through the 7-day rotation.
    const mode = onchain.wallet === zeroAddress || onchain.wallet === s.wallet ? "attest" : "initiateRotation";
    // The contract compares expiry with block.timestamp: never start from a clock that is behind the chain.
    const chainNow = await deps.chain.latestTimestamp();
    const expiry = Math.max(Math.floor(now() / 1000), chainNow) + attestationTtl;
    const nonce = bytesToHex(random(32));
    const signature = await deps.signer.sign(
      { platform: tag, platformUserId: creatorId, wallet: s.wallet, expiry, nonce },
      { chainId: deps.chain.chainId, verifyingContract: deps.attestor },
    );
    deps.store.set({ ...s, used: true, attestationNonce: nonce });

    return c.json({
      mode,
      contract: deps.attestor,
      functionName: mode,
      args: [tag, creatorId, s.wallet, expiry, nonce, signature],
      creatorId,
      identity: s.identity,
      ...(mode === "initiateRotation" ? { currentWallet: onchain.wallet } : {}),
    });
  });

  return app;
}
