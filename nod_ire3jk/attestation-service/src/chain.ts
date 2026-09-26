import { createPublicClient, http, zeroAddress, type Address, type Hex, type PublicClient } from "viem";

const attestorAbi = [
  { type: "function", name: "walletOf", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "address" }] },
  { type: "function", name: "platformOf", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bytes32" }] },
  {
    type: "function", name: "attestations", stateMutability: "view", inputs: [{ type: "bytes32" }],
    outputs: [
      { name: "wallet", type: "address" }, { name: "pendingWallet", type: "address" },
      { name: "pendingWalletActivatesAt", type: "uint48" }, { name: "firstAttestedAt", type: "uint48" },
      { name: "lastAttestedAt", type: "uint48" }, { name: "revoked", type: "bool" },
    ],
  },
] as const;

export type IdentityState = {
  wallet: Address;
  platform: Hex;
  revoked: boolean;
};

/** On-chain reads and wallet-signature checks. Swappable in tests. */
export interface Chain {
  chainId: number;
  identityState(creatorId: Hex): Promise<IdentityState>;
  /** EOA and smart-account (ERC-1271 / ERC-6492) signatures. */
  verifyWalletSignature(wallet: Address, message: string, signature: Hex): Promise<boolean>;
}

export function viemChain(rpcUrl: string, chainId: number, attestor: Address): Chain {
  const client: PublicClient = createPublicClient({ transport: http(rpcUrl) });
  return {
    chainId,
    async identityState(creatorId) {
      const [rec, platform] = await Promise.all([
        client.readContract({ address: attestor, abi: attestorAbi, functionName: "attestations", args: [creatorId] }),
        client.readContract({ address: attestor, abi: attestorAbi, functionName: "platformOf", args: [creatorId] }),
      ]);
      return { wallet: rec[0] ?? zeroAddress, platform, revoked: rec[5] };
    },
    verifyWalletSignature(wallet, message, signature) {
      return client.verifyMessage({ address: wallet, message, signature });
    },
  };
}
