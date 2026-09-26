import type { Address, Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export type AttestationMessage = {
  platform: Hex;
  platformUserId: Hex;
  wallet: Address;
  expiry: number;
  nonce: Hex;
};

/**
 * Holder of the ATTESTER_ROLE key. The local-key signer is for local and testnet use;
 * in production the key belongs in a KMS/HSM or a Circle developer-controlled wallet
 * (both can sign EIP-712 typed data) behind this same interface.
 */
export interface AttestationSigner {
  address: Address;
  sign(message: AttestationMessage, domain: { chainId: number; verifyingContract: Address }): Promise<Hex>;
}

export const ATTESTATION_TYPES = {
  Attestation: [
    { name: "platform", type: "bytes32" },
    { name: "platformUserId", type: "bytes32" },
    { name: "wallet", type: "address" },
    { name: "expiry", type: "uint48" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

export function localKeySigner(privateKey: Hex): AttestationSigner {
  const account = privateKeyToAccount(privateKey);
  return {
    address: account.address,
    sign(message, domain) {
      return account.signTypedData({
        domain: { name: "NodIdentityAttestor", version: "1", ...domain },
        types: ATTESTATION_TYPES,
        primaryType: "Attestation",
        message: { ...message, expiry: message.expiry },
      });
    },
  };
}
