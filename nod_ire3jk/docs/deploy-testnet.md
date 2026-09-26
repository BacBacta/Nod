# Deploying Nod on Arc Testnet

Arc Testnet: chain ID `5042002`, RPC `https://rpc.testnet.arc.io`, explorer
`https://explorer.testnet.arc.io`, gas paid in USDC from `https://faucet.circle.com`.

Bullcheese is not deployed on Arc Testnet. `NOD_DEMO_LAUNCHPAD=true` deploys a demo
launchpad (`MockLaunchpad` plus its adapter) so the app can be used end to end.

## 1. Prepare (once)

```bash
cd nod_ire3jk
bun install && git clone --depth 1 --branch v1.16.2 https://github.com/foundry-rs/forge-std lib/forge-std
forge test                                           # everything green before deploying

# Deployer key: an encrypted keystore, never an env var
cast wallet import nod-deployer --interactive
# Testnet only: the multisig may be an EOA; it proposes and executes timelock operations
cast wallet import nod-multisig --interactive
```

Fund both addresses with testnet USDC from https://faucet.circle.com.

Create `.env` from `docs/env-example.md`, then:

```bash
source .env
```

## 2. Deploy

```bash
NOD_DEMO_LAUNCHPAD=true forge script contracts/script/DeployNod.s.sol \
  --rpc-url https://rpc.testnet.arc.io --account nod-deployer --broadcast
```

The script deploys the six contracts and, with the flag set, the demo launchpad. It
hands every admin role to the timelock; the deployer keeps none. It then writes all
addresses to `frontend/src/deployments/5042002.json`, which the frontend reads. Commit
that file.

## 3. Admin operations through the 48h timelock

This step whitelists the demo adapter and, optionally, sets the swap router and the
Registry keeper.

```bash
MODE=schedule forge script contracts/script/TimelockOps.s.sol \
  --rpc-url https://rpc.testnet.arc.io --account nod-multisig --broadcast
# 48 hours later, with the same variables:
MODE=execute forge script contracts/script/TimelockOps.s.sol \
  --rpc-url https://rpc.testnet.arc.io --account nod-multisig --broadcast
```

Optional variables:
- `NOD_ADAPTERS` is a comma-separated list; the default is the demo adapter.
- `NOD_SWAP_ROUTER` sets the router used to convert token fees.
- `NOD_REGISTRY_KEEPER` grants `KEEPER_ROLE` on the Registry.
- `NOD_TIMELOCK_SALT` is needed for a second batch.

With a Safe multisig, run the script without `--broadcast` and submit the printed
targets and payloads with the Safe transaction builder.

## 4. Attestation service and frontend

- **Attestation service:** `ATTESTOR_ADDRESS` comes from the JSON, with `CHAIN_ID=5042002`
  and `RPC_URL=https://rpc.testnet.arc.io`. `ATTESTER_PRIVATE_KEY` must hold
  `NOD_ATTESTER`'s role. See `attestation-service/README.md` and its `.env.example`.
- **Frontend:** set `VITE_ATTESTATION_URL` to the service's public URL, then run
  `bun run build`.

## 5. Check

- `cast call <registry> "whitelistedAdapters(address)(bool)" <adapter> --rpc-url https://rpc.testnet.arc.io`
  returns `true` after step 3.
- For each contract, `hasRole(DEFAULT_ADMIN_ROLE, <deployer>)` returns `false`, and
  `hasRole(DEFAULT_ADMIN_ROLE, <timelock>)` returns `true`.
- In the app: verify an identity, register a demo token (set its fee recipient on the
  demo launchpad to the predicted vault first), accept it, and claim.
