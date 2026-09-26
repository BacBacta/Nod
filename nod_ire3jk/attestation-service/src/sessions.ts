import type { Address, Hex } from "viem";
import type { Platform, VerifiedIdentity } from "./identity";

export type Session = {
  id: string;
  wallet: Address;
  /** Random nonce embedded in the wallet challenge and the SIWF message. */
  nonce: string;
  challenge: string;
  walletVerified: boolean;
  identity?: VerifiedIdentity;
  oauth?: { platform: Platform; state: string; codeVerifier: string };
  expiresAt: number;
  used: boolean;
  attestationNonce?: Hex;
};

/** Pending verification sessions. In-memory by default; use a shared store (e.g. Redis) when running several instances. */
export interface SessionStore {
  get(id: string): Session | undefined;
  set(session: Session): void;
  findByOAuthState(state: string): Session | undefined;
}

export class MemorySessionStore implements SessionStore {
  private sessions = new Map<string, Session>();

  constructor(private now: () => number = Date.now) {}

  get(id: string): Session | undefined {
    const s = this.sessions.get(id);
    if (s && s.expiresAt <= this.now()) {
      this.sessions.delete(id);
      return undefined;
    }
    return s;
  }

  set(session: Session): void {
    this.sweep();
    this.sessions.set(session.id, session);
  }

  findByOAuthState(state: string): Session | undefined {
    for (const s of this.sessions.values()) {
      if (s.oauth?.state === state) return this.get(s.id);
    }
    return undefined;
  }

  private sweep(): void {
    const t = this.now();
    for (const [id, s] of this.sessions) if (s.expiresAt <= t) this.sessions.delete(id);
  }
}
