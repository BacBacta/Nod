// Minimal ABIs used by the keeper (subset of contracts/Registry.sol and FeeVault.sol).
export const registryAbi = [
  { type: "event", name: "TokenRegistered", inputs: [
    { name: "token", type: "address", indexed: true },
    { name: "vault", type: "address", indexed: true },
    { name: "creatorId", type: "bytes32", indexed: true },
    { name: "fallbackRecipient", type: "address", indexed: false },
  ] },
  { type: "function", name: "collectFees", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }], outputs: [] },
  { type: "function", name: "prepareSwapOracle", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }, { name: "cardinalityNext", type: "uint16" }], outputs: [] },
  { type: "function", name: "swapFloor", stateMutability: "view", inputs: [{ name: "token", type: "address" }, { name: "amountIn", type: "uint256" }], outputs: [{ name: "twapOut", type: "uint256" }, { name: "floor", type: "uint256" }] },
  { type: "function", name: "swapTokenFees", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minUsdcOut", type: "uint256" }], outputs: [] },
  { type: "error", name: "AccessControlUnauthorizedAccount", inputs: [{ name: "account", type: "address" }, { name: "neededRole", type: "bytes32" }] },
  { type: "error", name: "MinOutBelowTwap", inputs: [{ name: "minOut", type: "uint256" }, { name: "floor", type: "uint256" }] },
  { type: "error", name: "SwapRouterNotSet", inputs: [] },
  { type: "error", name: "NoUsdcPool", inputs: [{ name: "token", type: "address" }] },
  { type: "error", name: "InvalidSwapAmount", inputs: [{ name: "amountIn", type: "uint256" }] },
  { type: "error", name: "TokenNotRegistered", inputs: [{ name: "token", type: "address" }] },
] as const;

export const vaultAbi = [
  { type: "function", name: "feeSource", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
] as const;
