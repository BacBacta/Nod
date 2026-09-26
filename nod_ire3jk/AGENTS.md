# Nod Protocol — Project Memory

## Contract Source Files

| Contract | File | Description |
|---|---|---|
| NodTimelockController | contracts/NodTimelockController.sol | OZ TimelockController wrapper, 48h min delay. DEFAULT_ADMIN of all contracts after bootstrap. |
| ILaunchpadAdapter | contracts/ILaunchpadAdapter.sol | Interface: verifyFeeRecipient(token, vault) |
| BullcheeseAdapter | contracts/BullcheeseAdapter.sol | Bullcheese launchpad adapter stub (verifies fee recipient + immutability lock) |
| FeeVault | contracts/FeeVault.sol | Per-token non-upgradeable USDC vault. ERC-20-only accounting; receive() accepts native USDC (same pool, counted via balanceOf). Accrual ledger: credit() / withdrawFor(). |
| FeeVaultFactory | contracts/FeeVaultFactory.sol | CREATE2 factory. Salt = keccak256(deployer, nonce). admin-gated setRegistry. predictVaultAddress(deployer, token) requires real token arg. |
| IdentityAttestor | contracts/IdentityAttestor.sol | EIP-712 attestations keyed by platformUserId (bytes32). 7-day rotation delay, 7-day first-claim cooldown, replay protection. |
| Registry | contracts/Registry.sol | Core 5-state-per-token + per-recipient state machine. Accrual distribution (credit for splits, push for treasury/buyback/fallback). Claim pause limited to 72h. |
| PayoutRouter | contracts/PayoutRouter.sol | Pull-based claim() and batchClaim(). Reads vault.claimable(wallet). Payout override support. |
| BuybackModule | contracts/BuybackModule.sol | Keeper-scheduled Uniswap V3 USDC→NOD swap. Accumulate-until-NOD-set mode. Disable switch. |

## Key Constants (Arc Testnet)
- USDC ERC-20: 0x3600000000000000000000000000000000000000 (6 decimals)
- Chain ID: 5042002

## Deployed Contracts
(none yet — not deployed)

## Assumptions
- Splits dust → first recipient
- Per-recipient deadline = same 14-day token deadline
- All splits recipients must sign any splits change
- BuybackModule starts disabled / accumulate mode (no NOD token set)
- Claim pause auto-lifts after 72h (cannot be chained)
- notifyReceived() is permissionless (safe: balance-delta only)
