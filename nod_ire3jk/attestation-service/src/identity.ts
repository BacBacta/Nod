import { encodeAbiParameters, keccak256, stringToBytes, type Hex } from "viem";

export const PLATFORMS = ["x", "farcaster", "github", "tiktok", "reddit"] as const;
export type Platform = (typeof PLATFORMS)[number];

export function isPlatform(p: string): p is Platform {
  return (PLATFORMS as readonly string[]).includes(p);
}

/** bytes32 platform tag used on-chain: keccak256 of the lowercase platform name. */
export function platformTag(p: Platform): Hex {
  return keccak256(stringToBytes(p));
}

/**
 * Canonical creator id, identical to IdentityAttestor.creatorIdOf(platform, externalId):
 * keccak256(abi.encode(bytes32 platform, string externalId)).  The external id is the
 * platform's immutable account id (never a handle).
 */
export function creatorIdOf(p: Platform, externalId: string): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "string" }], [platformTag(p), externalId]),
  );
}

export type VerifiedIdentity = {
  platform: Platform;
  /** Immutable platform account id (numeric id, FID, open_id...). */
  externalId: string;
  /** Display handle at verification time. Informational only, never used as a key. */
  handle?: string;
};
