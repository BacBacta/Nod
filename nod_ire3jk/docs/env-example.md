# Environment variables for Nod deployment

Copy these to a `.env` file in the project root and fill in every value before running the deploy script.

```bash
# Deployer private key (hex, no 0x prefix)
PRIVATE_KEY=

# Gnosis Safe (or EOA for testnet) — proposer + executor on the 48h timelock
NOD_MULTISIG=

# Key that signs EIP-712 identity attestations (ATTESTER_ROLE)
NOD_ATTESTER=

# Address that can pause registrations / attestations / buybacks (PAUSER_ROLE)
NOD_PAUSER=

# Keeper bot — calls BuybackModule.executeBuyback() on schedule (KEEPER_ROLE)
NOD_KEEPER=

# Protocol treasury — receives 50% of the 10% protocol fee
# Must not be a FeeVault or BuybackModule
NOD_TREASURY=

# First whitelisted fallback recipient (charity / community wallet)
NOD_FALLBACK1=

# Beta per-vault deposit cap in raw USDC (6-decimal units)
# Example: 10000000000 = 10,000 USDC.  Use 0 for no cap.
NOD_DEPOSIT_CAP=10000000000

# Initial protocol fee in basis points.  Max 1500 (15%).  Default 1000 (10%).
NOD_PROTOCOL_FEE=1000
```
