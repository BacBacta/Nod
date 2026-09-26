import { useState } from "react";
import type { Abi, ContractFunctionArgs, ContractFunctionName } from "viem";
import { useConfig } from "wagmi";
import {
  simulateContract, waitForTransactionReceipt, writeContract,
  type SimulateContractParameters,
} from "wagmi/actions";
import type { config as appConfig } from "./wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { errorMessage } from "./format";

type Status =
  | { kind: "idle" }
  | { kind: "pending"; label: string }
  | { kind: "done"; label: string }
  | { kind: "error"; label: string; message: string };

/**
 * Simulate, send and confirm a contract write, then refresh every on-chain read.
 * Simulating first surfaces the contract's custom error name before any gas is spent.
 */
export function useTx() {
  const config = useConfig();
  const queryClient = useQueryClient();
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  async function send<
    const abi extends Abi | readonly unknown[],
    functionName extends ContractFunctionName<abi, "nonpayable" | "payable">,
    args extends ContractFunctionArgs<abi, "nonpayable" | "payable", functionName>,
  >(
    label: string,
    params: SimulateContractParameters<abi, functionName, args, typeof appConfig>,
  ) {
    setStatus({ kind: "pending", label });
    try {
      // Params are fully typed at the call site; the cast only drops the generics here.
      const { request } = await simulateContract(config, params as never);
      const hash = await writeContract(config, request);
      const receipt = await waitForTransactionReceipt(config, { hash });
      if (receipt.status !== "success") throw new Error("Transaction annulée (revert).");
      setStatus({ kind: "done", label });
      await queryClient.invalidateQueries();
      return true;
    } catch (err) {
      setStatus({ kind: "error", label, message: errorMessage(err) });
      return false;
    }
  }

  return { send, status, busy: status.kind === "pending" };
}

export type TxStatus = ReturnType<typeof useTx>["status"];
