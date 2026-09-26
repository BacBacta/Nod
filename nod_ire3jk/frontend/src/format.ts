import { formatUnits, BaseError, ContractFunctionRevertedError, type Address } from "viem";

/** USDC amounts are always shown in the 6-decimal ERC-20 view (see Circle use-arc). */
export function usdc(amount: bigint | undefined): string {
  if (amount === undefined) return "…";
  return `${Number(formatUnits(amount, 6)).toLocaleString("fr-FR", { maximumFractionDigits: 6 })} USDC`;
}

export const STATES = ["Non enregistré", "En attente", "Accepté", "Refusé", "Expiré"] as const;
export enum TokenState { NONE, PENDING, ACCEPTED, REFUSED, EXPIRED }

export function short(a: Address | undefined): string {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "…";
}

export function sameAddress(a?: string, b?: string): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

/** Human-readable message for a failed write, including the custom error name. */
export function errorMessage(err: unknown): string {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName) {
      return `Le contrat a refusé : ${revert.data.errorName}`;
    }
    return err.shortMessage;
  }
  return err instanceof Error ? err.message : String(err);
}
