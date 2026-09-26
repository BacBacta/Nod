import { describe, expect, it } from "vitest";
import { githubProvider, redditProvider, tiktokProvider, xProvider } from "../src/providers/oauth";

type Call = { url: string; init?: RequestInit };

/** Fake fetch: answers by URL prefix and records every call. */
function fakeFetch(routes: Record<string, unknown>) {
  const calls: Call[] = [];
  const f = (async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const key = Object.keys(routes).find((k) => url.startsWith(k));
    if (!key) return new Response("not found", { status: 404 });
    return new Response(JSON.stringify(routes[key]), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  return { f, calls };
}

const creds = { clientId: "cid", clientSecret: "secret" };
const args = { code: "the-code", redirectUri: "https://attest/cb", codeVerifier: "verifier" };
const body = (c: Call) => new URLSearchParams(String(c.init?.body));
const header = (c: Call, h: string) => new Headers(c.init?.headers).get(h);

describe("OAuth providers", () => {
  it("X: PKCE authorize URL, Basic auth token exchange, id from /2/users/me", async () => {
    const { f, calls } = fakeFetch({
      "https://api.x.com/2/oauth2/token": { access_token: "tok" },
      "https://api.x.com/2/users/me": { data: { id: "2244994945", username: "XDevelopers" } },
    });
    const p = xProvider(creds, f);
    const url = new URL(p.authorizeUrl({ state: "st", redirectUri: args.redirectUri, codeChallenge: "cc" }));
    expect(url.origin + url.pathname).toBe("https://x.com/i/oauth2/authorize");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("scope")).toBe("users.read tweet.read");

    expect(await p.identify(args)).toEqual({ platform: "x", externalId: "2244994945", handle: "XDevelopers" });
    expect(header(calls[0], "authorization")).toBe(`Basic ${Buffer.from("cid:secret").toString("base64")}`);
    expect(body(calls[0]).get("code_verifier")).toBe("verifier");
    expect(header(calls[1], "authorization")).toBe("Bearer tok");
  });

  it("GitHub: numeric id, not the login", async () => {
    const { f, calls } = fakeFetch({
      "https://github.com/login/oauth/access_token": { access_token: "tok" },
      "https://api.github.com/user": { id: 583231, login: "octocat" },
    });
    expect(await githubProvider(creds, f).identify(args)).toEqual({ platform: "github", externalId: "583231", handle: "octocat" });
    expect(body(calls[0]).get("client_secret")).toBe("secret");
    expect(header(calls[0], "accept")).toBe("application/json");
  });

  it("GitHub: an error response is not an identity", async () => {
    const { f } = fakeFetch({ "https://github.com/login/oauth/access_token": { error: "bad_verification_code" } });
    await expect(githubProvider(creds, f).identify(args)).rejects.toThrow("bad_verification_code");
  });

  it("TikTok: client_key params, open_id must match the token's", async () => {
    const { f, calls } = fakeFetch({
      "https://open.tiktokapis.com/v2/oauth/token/": { access_token: "tok", open_id: "oid-1" },
      "https://open.tiktokapis.com/v2/user/info/": { data: { user: { open_id: "oid-1", display_name: "Tik" } } },
    });
    const p = tiktokProvider(creds, f);
    const url = new URL(p.authorizeUrl({ state: "st", redirectUri: args.redirectUri, codeChallenge: "cc" }));
    expect(url.searchParams.get("client_key")).toBe("cid");
    expect(url.searchParams.get("scope")).toBe("user.info.basic");
    expect(await p.identify(args)).toEqual({ platform: "tiktok", externalId: "oid-1", handle: "Tik" });
    expect(body(calls[0]).get("grant_type")).toBe("authorization_code");

    const bad = fakeFetch({
      "https://open.tiktokapis.com/v2/oauth/token/": { access_token: "tok", open_id: "oid-1" },
      "https://open.tiktokapis.com/v2/user/info/": { data: { user: { open_id: "someone-else" } } },
    });
    await expect(tiktokProvider(creds, bad.f).identify(args)).rejects.toThrow("different account");
  });

  it("Reddit: Basic auth, User-Agent, identity scope, id from /api/v1/me", async () => {
    const { f, calls } = fakeFetch({
      "https://www.reddit.com/api/v1/access_token": { access_token: "tok" },
      "https://oauth.reddit.com/api/v1/me": { id: "1w72", name: "spez" },
    });
    const p = redditProvider(creds, f);
    const url = new URL(p.authorizeUrl({ state: "st", redirectUri: args.redirectUri, codeChallenge: "cc" }));
    expect(url.searchParams.get("scope")).toBe("identity");
    expect(url.searchParams.get("duration")).toBe("temporary");
    expect(await p.identify(args)).toEqual({ platform: "reddit", externalId: "1w72", handle: "spez" });
    expect(header(calls[0], "user-agent")).toMatch(/nod-attestation/);
    expect(header(calls[1], "authorization")).toBe("bearer tok");
  });

  it("HTTP errors never become identities", async () => {
    const { f } = fakeFetch({});
    await expect(xProvider(creds, f).identify(args)).rejects.toThrow("HTTP 404");
  });
});
