import { serve } from "@hono/node-server";
import { isAddress, isHex, type Address, type Hex } from "viem";
import { z } from "zod";
import { createApp } from "./app";
import { viemChain } from "./chain";
import { farcasterVerifier } from "./providers/farcaster";
import { githubProvider, redditProvider, tiktokProvider, xProvider, type OAuthProvider } from "./providers/oauth";
import { MemorySessionStore } from "./sessions";
import { localKeySigner } from "./signer";

const env = z
  .object({
    PORT: z.coerce.number().default(8787),
    PUBLIC_URL: z.string().url(),
    FRONTEND_URL: z.string().url(),
    RPC_URL: z.string().url(),
    CHAIN_ID: z.coerce.number(),
    ATTESTOR_ADDRESS: z.string().refine(isAddress),
    ATTESTER_PRIVATE_KEY: z.string().refine((v) => isHex(v) && v.length === 66),
    OPTIMISM_RPC_URL: z.string().url().optional(),
    FARCASTER_ENABLED: z.enum(["true", "false"]).default("true"),
    X_CLIENT_ID: z.string().optional(), X_CLIENT_SECRET: z.string().optional(),
    GITHUB_CLIENT_ID: z.string().optional(), GITHUB_CLIENT_SECRET: z.string().optional(),
    TIKTOK_CLIENT_KEY: z.string().optional(), TIKTOK_CLIENT_SECRET: z.string().optional(),
    REDDIT_CLIENT_ID: z.string().optional(), REDDIT_CLIENT_SECRET: z.string().optional(),
  })
  .parse(process.env);

// A platform is enabled only when both of its credentials are set.
const creds = (id?: string, secret?: string) => (id && secret ? { clientId: id, clientSecret: secret } : undefined);
const oauth: Partial<Record<OAuthProvider["platform"], OAuthProvider>> = {};
const x = creds(env.X_CLIENT_ID, env.X_CLIENT_SECRET);
if (x) oauth.x = xProvider(x);
const gh = creds(env.GITHUB_CLIENT_ID, env.GITHUB_CLIENT_SECRET);
if (gh) oauth.github = githubProvider(gh);
const tt = creds(env.TIKTOK_CLIENT_KEY, env.TIKTOK_CLIENT_SECRET);
if (tt) oauth.tiktok = tiktokProvider(tt);
const rd = creds(env.REDDIT_CLIENT_ID, env.REDDIT_CLIENT_SECRET);
if (rd) oauth.reddit = redditProvider(rd);

const signer = localKeySigner(env.ATTESTER_PRIVATE_KEY as Hex);
const app = createApp({
  store: new MemorySessionStore(),
  chain: viemChain(env.RPC_URL, env.CHAIN_ID, env.ATTESTOR_ADDRESS as Address),
  signer,
  attestor: env.ATTESTOR_ADDRESS as Address,
  oauth,
  farcaster: env.FARCASTER_ENABLED === "true" ? farcasterVerifier(env.OPTIMISM_RPC_URL) : undefined,
  publicUrl: env.PUBLIC_URL.replace(/\/$/, ""),
  frontendUrl: env.FRONTEND_URL,
});

serve({ fetch: app.fetch, port: env.PORT }, () => {
  const enabled = [...Object.keys(oauth), ...(env.FARCASTER_ENABLED === "true" ? ["farcaster"] : [])];
  console.log(`Nod attestation service on :${env.PORT} — attester ${signer.address} — platforms: ${enabled.join(", ") || "none"}`);
});
