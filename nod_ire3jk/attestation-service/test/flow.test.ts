import { describe, expect, it, vi } from "vitest";
import { recoverTypedDataAddress, type Hex } from "viem";
import { creatorIdOf, platformTag } from "../src/identity";
import type { OAuthProvider } from "../src/providers/oauth";
import { ATTESTATION_TYPES } from "../src/signer";
import { ATTESTOR, FRONTEND, OTHER, PUBLIC, USER, fakeChain, makeApp, post, verifiedSession } from "./helpers";

const ghIdentity = { platform: "github" as const, externalId: "583231", handle: "octocat" };

function fakeGithub(identify = vi.fn(async () => ghIdentity)): OAuthProvider & { identify: typeof identify } {
  return {
    platform: "github",
    authorizeUrl: ({ state, redirectUri, codeChallenge }) =>
      `https://github.example/authorize?state=${state}&redirect_uri=${encodeURIComponent(redirectUri)}&cc=${codeChallenge}`,
    identify,
  };
}

async function oauthRoundTrip(app: Awaited<ReturnType<typeof makeApp>>["app"], sessionId: string, code = "good-code") {
  const start = await app.request(`/v1/sessions/${sessionId}/oauth/github`);
  expect(start.status).toBe(302);
  const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
  const cb = await app.request(`/v1/oauth/github/callback?code=${code}&state=${state}`);
  return { state, cb, location: new URL(cb.headers.get("location")!) };
}

describe("attestation flow", () => {
  it("wallet proof + GitHub OAuth -> attestation signed by the attester", async () => {
    const github = fakeGithub();
    const { app } = makeApp({ oauth: { github } });
    const { sessionId } = await verifiedSession(app);

    const { location } = await oauthRoundTrip(app, sessionId);
    expect(location.origin).toBe(FRONTEND);
    expect(location.searchParams.get("verify")).toBe("ok");
    expect(location.searchParams.get("session")).toBe(sessionId);
    expect(github.identify).toHaveBeenCalledWith(
      expect.objectContaining({ code: "good-code", redirectUri: `${PUBLIC}/v1/oauth/github/callback` }),
    );

    const res = await post(app, `/v1/sessions/${sessionId}/attestation`, {});
    expect(res.status).toBe(200);
    expect(res.body.mode).toBe("attest");
    const [platform, platformUserId, wallet, expiry, nonce, signature] = res.body.args;
    expect(platform).toBe(platformTag("github"));
    expect(platformUserId).toBe(creatorIdOf("github", "583231"));
    expect(wallet).toBe(USER.address);

    const signer = await recoverTypedDataAddress({
      domain: { name: "NodIdentityAttestor", version: "1", chainId: 5042002, verifyingContract: ATTESTOR },
      types: ATTESTATION_TYPES, primaryType: "Attestation",
      message: { platform, platformUserId, wallet, expiry, nonce },
      signature: signature as Hex,
    });
    expect(signer).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  });

  it("sessions are single use", async () => {
    const { app } = makeApp({ oauth: { github: fakeGithub() } });
    const { sessionId } = await verifiedSession(app);
    await oauthRoundTrip(app, sessionId);
    expect((await post(app, `/v1/sessions/${sessionId}/attestation`, {})).status).toBe(200);
    const again = await post(app, `/v1/sessions/${sessionId}/attestation`, {});
    expect(again.status).toBe(409);
    expect(again.body.error).toBe("session_used");
  });

  it("refuses to attest without both proofs", async () => {
    const { app } = makeApp({ oauth: { github: fakeGithub() } });
    const start = await post(app, "/v1/sessions", { wallet: USER.address });
    const noWallet = await post(app, `/v1/sessions/${start.body.sessionId}/attestation`, {});
    expect(noWallet.body.error).toBe("wallet_not_verified");

    const { sessionId } = await verifiedSession(app);
    const noIdentity = await post(app, `/v1/sessions/${sessionId}/attestation`, {});
    expect(noIdentity.body.error).toBe("identity_not_verified");
  });

  it("rejects a wallet signature from another key", async () => {
    const { app } = makeApp();
    const start = await post(app, "/v1/sessions", { wallet: USER.address });
    const signature = await OTHER.signMessage({ message: start.body.message });
    const r = await post(app, `/v1/sessions/${start.body.sessionId}/wallet-signature`, { signature });
    expect(r.status).toBe(400);
  });

  it("OAuth needs a verified wallet first", async () => {
    const { app } = makeApp({ oauth: { github: fakeGithub() } });
    const start = await post(app, "/v1/sessions", { wallet: USER.address });
    const r = await app.request(`/v1/sessions/${start.body.sessionId}/oauth/github`);
    expect(r.status).toBe(409);
  });

  it("OAuth state is single use and bound to its platform", async () => {
    const github = fakeGithub();
    const { app } = makeApp({ oauth: { github } });
    const { sessionId } = await verifiedSession(app);
    const { state } = await oauthRoundTrip(app, sessionId);

    const replay = await app.request(`/v1/oauth/github/callback?code=x&state=${state}`);
    expect(new URL(replay.headers.get("location")!).searchParams.get("verify")).toBe("invalid_state");

    const { sessionId: s2 } = await verifiedSession(app);
    const start = await app.request(`/v1/sessions/${s2}/oauth/github`);
    const state2 = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const wrongPlatform = await app.request(`/v1/oauth/x/callback?code=x&state=${state2}`);
    expect(new URL(wrongPlatform.headers.get("location")!).searchParams.get("verify")).toBe("invalid_state");
    expect(github.identify).toHaveBeenCalledTimes(1);
  });

  it("a provider failure does not verify the identity", async () => {
    const github = fakeGithub(vi.fn(async () => { throw new Error("HTTP 401"); }));
    const { app } = makeApp({ oauth: { github } });
    const { sessionId } = await verifiedSession(app);
    const { location } = await oauthRoundTrip(app, sessionId);
    expect(location.searchParams.get("verify")).toBe("provider_error");
    expect((await post(app, `/v1/sessions/${sessionId}/attestation`, {})).body.error).toBe("identity_not_verified");
  });

  it("an existing identity with another wallet gets a rotation, not an instant change", async () => {
    const id = creatorIdOf("github", "583231");
    const { app } = makeApp({
      oauth: { github: fakeGithub() },
      chain: fakeChain({ [id]: { wallet: OTHER.address, platform: platformTag("github") } }),
    });
    const { sessionId } = await verifiedSession(app);
    await oauthRoundTrip(app, sessionId);
    const res = await post(app, `/v1/sessions/${sessionId}/attestation`, {});
    expect(res.body.mode).toBe("initiateRotation");
    expect(res.body.currentWallet).toBe(OTHER.address);
  });

  it("re-attesting the same wallet is a plain attest", async () => {
    const id = creatorIdOf("github", "583231");
    const { app } = makeApp({
      oauth: { github: fakeGithub() },
      chain: fakeChain({ [id]: { wallet: USER.address, platform: platformTag("github") } }),
    });
    const { sessionId } = await verifiedSession(app);
    await oauthRoundTrip(app, sessionId);
    expect((await post(app, `/v1/sessions/${sessionId}/attestation`, {})).body.mode).toBe("attest");
  });

  it("refuses revoked identities and platform mismatches", async () => {
    const id = creatorIdOf("github", "583231");
    for (const [state, error] of [
      [{ revoked: true }, "identity_revoked"],
      [{ platform: platformTag("x") }, "platform_mismatch"],
    ] as const) {
      const { app } = makeApp({ oauth: { github: fakeGithub() }, chain: fakeChain({ [id]: state }) });
      const { sessionId } = await verifiedSession(app);
      await oauthRoundTrip(app, sessionId);
      expect((await post(app, `/v1/sessions/${sessionId}/attestation`, {})).body.error).toBe(error);
    }
  });

  it("sessions expire", async () => {
    const { app, advance } = makeApp();
    const start = await post(app, "/v1/sessions", { wallet: USER.address });
    advance(15 * 60_000 + 1);
    const r = await app.request(`/v1/sessions/${start.body.sessionId}`);
    expect(r.status).toBe(404);
  });

  it("Farcaster: verifies SIWF with the session nonce and the frontend domain", async () => {
    const verify = vi.fn(async () => ({ platform: "farcaster" as const, externalId: "3621" }));
    const { app } = makeApp({ farcaster: { verify } });
    const { sessionId, nonce } = await verifiedSession(app);
    const r = await post(app, `/v1/sessions/${sessionId}/farcaster`, { message: "siwf message", signature: "0x1234" });
    expect(r.status).toBe(200);
    expect(verify).toHaveBeenCalledWith({ message: "siwf message", signature: "0x1234", nonce, domain: "app.nod.test" });
    expect(r.body.identity.creatorId).toBe(creatorIdOf("farcaster", "3621"));
    const att = await post(app, `/v1/sessions/${sessionId}/attestation`, {});
    expect(att.body.args[0]).toBe(platformTag("farcaster"));
  });

  it("Farcaster: an invalid sign-in is rejected", async () => {
    const verify = vi.fn(async () => { throw new Error("bad signature"); });
    const { app } = makeApp({ farcaster: { verify } });
    const { sessionId } = await verifiedSession(app);
    const r = await post(app, `/v1/sessions/${sessionId}/farcaster`, { message: "m", signature: "0x12" });
    expect(r.status).toBe(400);
    expect(r.body.error).toBe("farcaster_invalid");
  });

  it("lists only configured platforms", async () => {
    const { app } = makeApp({ oauth: { github: fakeGithub() } });
    const r = await app.request("/v1/platforms");
    const body = (await r.json()) as any;
    expect(body.platforms).toEqual([{ id: "github", method: "oauth" }]);
    expect(body.attestor).toBe(ATTESTOR);
  });
});
