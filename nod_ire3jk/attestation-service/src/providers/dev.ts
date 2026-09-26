import type { Hono } from "hono";
import type { Platform } from "../identity";
import type { OAuthProvider } from "./oauth";

/**
 * LOCAL DEVELOPMENT ONLY. Stands in for a real OAuth provider: its consent page lets you
 * type any account id, which is then treated as verified. server.ts refuses to enable
 * it unless CHAIN_ID is 31337 (anvil).
 */
export function devProvider(platform: Exclude<Platform, "farcaster">, publicUrl: string): OAuthProvider {
  return {
    platform,
    authorizeUrl: ({ state, redirectUri }) =>
      `${publicUrl}/dev/authorize?${new URLSearchParams({ platform, state, redirect_uri: redirectUri })}`,
    async identify({ code }) {
      return { platform, externalId: code, handle: `dev-${code}` };
    },
  };
}

const escape = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Fake consent page for devProvider. */
export function mountDevConsent(app: Hono) {
  app.get("/dev/authorize", (c) => {
    const { platform = "", state = "", redirect_uri = "" } = c.req.query();
    return c.html(`<!doctype html><meta charset="utf-8"><title>Fake ${escape(platform)} login</title>
<body style="font-family:system-ui;max-width:420px;margin:40px auto">
<h1>Connexion simulée : ${escape(platform)}</h1>
<p>Développement local uniquement. L'identifiant saisi est considéré comme vérifié.</p>
<form method="get" action="${escape(redirect_uri)}">
  <input type="hidden" name="state" value="${escape(state)}">
  <label>Identifiant du compte <input name="code" value="12345" required></label>
  <button type="submit">Autoriser</button>
</form></body>`);
  });
}
