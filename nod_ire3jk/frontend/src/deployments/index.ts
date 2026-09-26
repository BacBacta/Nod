import type { Address, Hex } from "viem";
import local from "./31337.json";
import arcTestnet from "./5042002.json";

export type Deployment = {
  chainId: number;
  usdc: Address;
  registry: Address;
  payoutRouter: Address;
  attestor: Address;
  factory: Address;
  adapter?: Address;
  fallback?: Address;
  demoToken?: Address;
  demoCreatorId?: Hex;
  bullcheeseAdapter?: Address;
  bullcheeseDemoToken?: Address;
};

// 31337.json is written by scripts/dev-local.sh; 5042002.json is filled in after
// the Arc Testnet deployment (DeployNod.s.sol output).
const all: Record<number, Partial<Deployment>> = {
  31337: local as Partial<Deployment>,
  5042002: arcTestnet as Partial<Deployment>,
};

export function deploymentFor(chainId: number | undefined): Deployment | undefined {
  if (chainId === undefined) return undefined;
  const d = all[chainId];
  return d?.registry ? (d as Deployment) : undefined;
}

export const hasLocalDeployment = Boolean((local as Partial<Deployment>).registry);
