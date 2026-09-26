import type { Address, Hex } from "viem";

export const ATTESTATION_URL: string =
  import.meta.env.VITE_ATTESTATION_URL ?? "http://localhost:8787";

export type PlatformInfo = { id: string; method: "oauth" | "siwf" };
export type Identity = { platform: string; externalId: string; handle?: string; creatorId: Hex };
export type Attestation = {
  mode: "attest" | "initiateRotation";
  contract: Address;
  functionName: "attest" | "initiateRotation";
  args: [Hex, Hex, Address, number, Hex, Hex];
  creatorId: Hex;
  currentWallet?: Address;
};

const MESSAGES: Record<string, string> = {
  invalid_wallet: "Adresse de wallet invalide.",
  invalid_signature: "La signature du wallet n'est pas valide.",
  session_not_found: "Session expirée. Recommencez.",
  session_used: "Cette session a déjà servi. Recommencez.",
  wallet_not_verified: "Le wallet n'a pas encore été vérifié.",
  identity_not_verified: "Le compte n'a pas encore été vérifié.",
  identity_revoked: "Cette identité a été révoquée.",
  platform_mismatch: "Cette identité est déjà rattachée à une autre plateforme.",
  platform_not_enabled: "Cette plateforme n'est pas activée sur le service.",
  farcaster_invalid: "La connexion Farcaster n'a pas pu être vérifiée.",
};

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${ATTESTATION_URL}${path}`, {
      ...init,
      headers: { "content-type": "application/json", ...init?.headers },
    });
  } catch {
    throw new Error("Service d'attestation injoignable.");
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(MESSAGES[body.error] ?? `Erreur du service (${body.error ?? res.status}).`);
  return body as T;
}

export const api = {
  platforms: () =>
    call<{ platforms: PlatformInfo[]; attestor: Address; chainId: number }>("/v1/platforms"),
  start: (wallet: Address) =>
    call<{ sessionId: string; message: string; nonce: string }>("/v1/sessions", {
      method: "POST", body: JSON.stringify({ wallet }),
    }),
  proveWallet: (id: string, signature: Hex) =>
    call<{ walletVerified: true }>(`/v1/sessions/${id}/wallet-signature`, {
      method: "POST", body: JSON.stringify({ signature }),
    }),
  session: (id: string) =>
    call<{ wallet: Address; walletVerified: boolean; identity?: Identity }>(`/v1/sessions/${id}`),
  oauthUrl: (id: string, platform: string) => `${ATTESTATION_URL}/v1/sessions/${id}/oauth/${platform}`,
  farcaster: (id: string, message: string, signature: Hex) =>
    call<{ identity: Identity }>(`/v1/sessions/${id}/farcaster`, {
      method: "POST", body: JSON.stringify({ message, signature }),
    }),
  attestation: (id: string) =>
    call<Attestation>(`/v1/sessions/${id}/attestation`, { method: "POST", body: "{}" }),
};
