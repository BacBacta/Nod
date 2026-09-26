# Nod keeper

Bot for pull-model launchpads (Bullcheese). Each run:

1. **Discovers tokens.** Reads `TokenRegistered` events and keeps those whose vault owns
   a fee source (`FeeVault.feeSource() != 0`).
2. **Collects fees.** Calls `Registry.collectFees(token)`, which is permissionless. The
   USDC share is distributed, and the token share stays in the vault.
3. **Prepares the price history.** Calls `prepareSwapOracle(token, ORACLE_CARDINALITY)`
   once per token, so the pool can serve a 10-minute TWAP.
4. **Converts token fees to USDC.** Calls `swapTokenFees(token, amount, floor)` with
   `floor` from `Registry.swapFloor`, which is the TWAP value minus 3%.
   - If the router refuses because the output is below the floor ("Too little
     received"), the keeper halves the amount and retries, up to `MAX_SPLITS` times.
   - Any other error, such as a missing role or no TWAP yet, is reported as is and
     retried on the next run.

The keeper key needs `KEEPER_ROLE` on the Registry, granted by the timelock, and no other
privilege. It can only sell a vault's token fees into USDC for that same vault, never
below the TWAP bound.

## Run

```bash
bun install
RPC_URL=https://rpc.mainnet.arc.io CHAIN_ID=5042 \
REGISTRY_ADDRESS=0x... REGISTRY_FROM_BLOCK=<deploy block> \
KEEPER_PRIVATE_KEY=0x... \
bun run start            # every INTERVAL_SECONDS (default 3600); ONCE=true for a single run
```

Optional settings: `ORACLE_CARDINALITY` (100), `MIN_TOKEN_FEES` (1, raw units),
`MAX_SPLITS` (4), `LOG_CHUNK_BLOCKS` (50000).

## Tests

```bash
../scripts/dev-local.sh                                  # fresh local stack
NOD_ANVIL_RPC=http://127.0.0.1:8545 bun run test
```

The tests cover three cases:
- collect plus conversion;
- a swap refused at the TWAP floor, then accepted once the price is back;
- a key without `KEEPER_ROLE` is refused, with the reason reported.
