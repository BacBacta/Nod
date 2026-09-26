import type { Platform, VerifiedIdentity } from "../identity";

export type OAuthCredentials = { clientId: string; clientSecret: string };

export type OAuthProvider = {
  platform: Exclude<Platform, "farcaster">;
  /** Provider consent URL for this request. */
  authorizeUrl(p: { state: string; redirectUri: string; codeChallenge: string }): string;
  /** Exchange the code and return the account's immutable id. Tokens are discarded. */
  identify(p: { code: string; redirectUri: string; codeVerifier: string }): Promise<VerifiedIdentity>;
};

type Fetch = typeof fetch;

async function json<T>(res: Response, what: string): Promise<T> {
  if (!res.ok) throw new Error(`${what} failed: HTTP ${res.status}`);
  return (await res.json()) as T;
}

function basic(c: OAuthCredentials): string {
  return `Basic ${Buffer.from(`${c.clientId}:${c.clientSecret}`).toString("base64")}`;
}

const form = (o: Record<string, string>) => new URLSearchParams(o).toString();
const FORM = "application/x-www-form-urlencoded";

/** X (Twitter): OAuth 2.0 authorization code with PKCE; id from GET /2/users/me. */
export function xProvider(c: OAuthCredentials, f: Fetch = fetch): OAuthProvider {
  return {
    platform: "x",
    authorizeUrl: ({ state, redirectUri, codeChallenge }) =>
      `https://x.com/i/oauth2/authorize?${new URLSearchParams({
        response_type: "code", client_id: c.clientId, redirect_uri: redirectUri,
        scope: "users.read tweet.read", state,
        code_challenge: codeChallenge, code_challenge_method: "S256",
      })}`,
    async identify({ code, redirectUri, codeVerifier }) {
      const token = await json<{ access_token: string }>(
        await f("https://api.x.com/2/oauth2/token", {
          method: "POST",
          headers: { "content-type": FORM, authorization: basic(c) },
          body: form({ grant_type: "authorization_code", code, redirect_uri: redirectUri, code_verifier: codeVerifier }),
        }),
        "X token exchange",
      );
      const me = await json<{ data: { id: string; username: string } }>(
        await f("https://api.x.com/2/users/me", { headers: { authorization: `Bearer ${token.access_token}` } }),
        "X user lookup",
      );
      return { platform: "x", externalId: me.data.id, handle: me.data.username };
    },
  };
}

/** GitHub: OAuth web flow; id from GET /user (numeric, survives renames). */
export function githubProvider(c: OAuthCredentials, f: Fetch = fetch): OAuthProvider {
  return {
    platform: "github",
    authorizeUrl: ({ state, redirectUri, codeChallenge }) =>
      `https://github.com/login/oauth/authorize?${new URLSearchParams({
        client_id: c.clientId, redirect_uri: redirectUri, state, scope: "",
        code_challenge: codeChallenge, code_challenge_method: "S256", allow_signup: "false",
      })}`,
    async identify({ code, redirectUri, codeVerifier }) {
      const token = await json<{ access_token?: string; error?: string }>(
        await f("https://github.com/login/oauth/access_token", {
          method: "POST",
          headers: { "content-type": FORM, accept: "application/json" },
          body: form({
            client_id: c.clientId, client_secret: c.clientSecret, code,
            redirect_uri: redirectUri, code_verifier: codeVerifier,
          }),
        }),
        "GitHub token exchange",
      );
      if (!token.access_token) throw new Error(`GitHub token exchange failed: ${token.error ?? "no token"}`);
      const me = await json<{ id: number; login: string }>(
        await f("https://api.github.com/user", {
          headers: { authorization: `Bearer ${token.access_token}`, accept: "application/vnd.github+json", "user-agent": "nod-attestation" },
        }),
        "GitHub user lookup",
      );
      return { platform: "github", externalId: String(me.id), handle: me.login };
    },
  };
}

/**
 * TikTok Login Kit v2. The id is `open_id`, which TikTok scopes to this app: keep the
 * same client key forever, or every creator's id changes.
 */
export function tiktokProvider(c: OAuthCredentials, f: Fetch = fetch): OAuthProvider {
  return {
    platform: "tiktok",
    authorizeUrl: ({ state, redirectUri }) =>
      `https://www.tiktok.com/v2/auth/authorize/?${new URLSearchParams({
        client_key: c.clientId, response_type: "code", scope: "user.info.basic",
        redirect_uri: redirectUri, state,
      })}`,
    async identify({ code, redirectUri }) {
      const token = await json<{ access_token?: string; open_id?: string; error?: string }>(
        await f("https://open.tiktokapis.com/v2/oauth/token/", {
          method: "POST",
          headers: { "content-type": FORM },
          body: form({
            client_key: c.clientId, client_secret: c.clientSecret, code,
            grant_type: "authorization_code", redirect_uri: redirectUri,
          }),
        }),
        "TikTok token exchange",
      );
      if (!token.access_token || !token.open_id) throw new Error(`TikTok token exchange failed: ${token.error ?? "no token"}`);
      const info = await json<{ data?: { user?: { open_id: string; display_name?: string } } }>(
        await f("https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name", {
          headers: { authorization: `Bearer ${token.access_token}` },
        }),
        "TikTok user lookup",
      );
      const user = info.data?.user;
      if (!user || user.open_id !== token.open_id) throw new Error("TikTok user lookup returned a different account");
      return { platform: "tiktok", externalId: user.open_id, handle: user.display_name };
    },
  };
}

/** Reddit: OAuth2 code flow, scope `identity`; id from GET /api/v1/me (base36, stable). */
export function redditProvider(c: OAuthCredentials, f: Fetch = fetch): OAuthProvider {
  const userAgent = "web:nod-attestation:0.1.0";
  return {
    platform: "reddit",
    authorizeUrl: ({ state, redirectUri }) =>
      `https://www.reddit.com/api/v1/authorize?${new URLSearchParams({
        client_id: c.clientId, response_type: "code", state, redirect_uri: redirectUri,
        duration: "temporary", scope: "identity",
      })}`,
    async identify({ code, redirectUri }) {
      const token = await json<{ access_token?: string; error?: string }>(
        await f("https://www.reddit.com/api/v1/access_token", {
          method: "POST",
          headers: { "content-type": FORM, authorization: basic(c), "user-agent": userAgent },
          body: form({ grant_type: "authorization_code", code, redirect_uri: redirectUri }),
        }),
        "Reddit token exchange",
      );
      if (!token.access_token) throw new Error(`Reddit token exchange failed: ${token.error ?? "no token"}`);
      const me = await json<{ id: string; name: string }>(
        await f("https://oauth.reddit.com/api/v1/me", {
          headers: { authorization: `bearer ${token.access_token}`, "user-agent": userAgent },
        }),
        "Reddit user lookup",
      );
      return { platform: "reddit", externalId: me.id, handle: me.name };
    },
  };
}
