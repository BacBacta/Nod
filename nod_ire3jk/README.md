# Nod Protocol — Creator-Fee Routing on Arc

Nod is a non-upgradeable, pull-based USDC fee-routing protocol for memecoin launchpads
on [Arc](https://arc.io) (Circle's L1, where USDC is the native gas token).

Launchpads fix a per-token **FeeVault** address as the fee recipient at token creation.
Fees accumulate there and are only released to creators who have verified their identity
and explicitly accepted the token.

---

## Contracts

| Contract | File | Purpose |
|---|---|---|
| `NodTimelockController` | `NodTimelockController.sol` | OZ `TimelockController` wrapper (48h min delay). Becomes `DEFAULT_ADMIN` of all other contracts after bootstrap. All privileged parameter changes go through it. |
| `FeeVaultFactory` | `FeeVaultFactory.sol` | Deploys one `FeeVault` per token via CREATE2. Salt = `keccak256(deployer, nonce)` — vault address is computable before the token exists. |
| `FeeVault` | `FeeVault.sol` | Non-upgradeable, per-token USDC vault. Uses accrual accounting (ERC-20 only — `address(this).balance` is never read). `receive()` accepts native USDC (same pool as the ERC-20 view), so launchpads may pay fees either way. |
| `ILaunchpadAdapter` | `ILaunchpadAdapter.sol` | Interface every launchpad adapter must implement: `verifyFeeRecipient(token, vault)`. |
| `BullcheeseAdapter` | `BullcheeseAdapter.sol` | Adapter for Bullcheese (Team Finance MintPlus) on Arc. Bullcheese pays creator fees to the owner of each token's LP locker, so the vault becomes that owner (see "Bullcheese integration"). |
| `IdentityAttestor` | `IdentityAttestor.sol` | EIP-712 identity registry. Maps immutable `platformUserId` (bytes32, never a handle) to a wallet address. Enforces 7-day rotation delay and 7-day first-claim cooldown. |
| `Registry` | `Registry.sol` | Core state machine. Manages token states (PENDING → ACCEPTED/REFUSED/EXPIRED), per-recipient sub-states, splits routing, protocol fee deduction, and expiry logic. |
| `PayoutRouter` | `PayoutRouter.sol` | Pull-based claim interface. Verified wallets call `claim(token, splitIndex)`. Supports a per-wallet payout override and gas-bounded `batchClaim`. |
| `BuybackModule` | `BuybackModule.sol` | Accumulates USDC from protocol fees. `executeBuyback()` swaps via Uniswap V3 on a keeper-enforced schedule, sending $NOD to `0x…dEaD`. Starts disabled until `nodToken` is set via timelock. |

---

## Roles

| Role | Holder | What it controls |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `NodTimelockController` (after bootstrap) | Grant / revoke roles; privileged setters on all contracts |
| `ATTESTER_ROLE` | Multisig off-chain signing key | Issue and revoke EIP-712 identity attestations |
| `KEEPER_ROLE` | Keeper EOA or bot | Call `BuybackModule.executeBuyback()` on schedule |
| `PAUSER_ROLE` | Fast-response EOA | Pause registrations, attestations, buybacks. Cannot pause creator claims of ACCEPTED balances for more than 72 hours. |
| `PAYOUT_ROUTER_ROLE` | `PayoutRouter` contract | The only address allowed to call `Registry.executeClaim` |

---

## State Machine (per token)

```
NONE ──registerToken()──► PENDING ──accept()──► ACCEPTED ──refuse()──► REFUSED
                               │                    │                       │
                               │                    │  (30-day lockout)     │
                               │                    └──────────────────────►│
                               │                                            │
                               └──expire() after 14d──► EXPIRED             │
                                                                            │
                          REFUSED ──accept() after 30d──► ACCEPTED ◄────────┘
```

### Fund routing

| Token state | Recipient state | USDC goes to |
|---|---|---|
| PENDING | any | Accumulates in vault (no distribution) |
| ACCEPTED | ACCEPTED | Recipient (minus 10% protocol fee) |
| ACCEPTED | PENDING | Held in vault for that recipient (`reservedOf`); released on accept (credited, minus fee), refuse (fallback), expiry (50/50) or token refusal (fallback) |
| ACCEPTED | REFUSED | `fallbackRecipient` |
| ACCEPTED | EXPIRED | 50% treasury / 50% BuybackModule |
| REFUSED | any | `fallbackRecipient` |
| EXPIRED | any | 50% treasury / 50% BuybackModule |

---

## Key Parameters

| Parameter | Location | Default | Governance |
|---|---|---|---|
| Protocol fee | `Registry.protocolFeeBps` | 1000 bps (10%) | Timelock (hard cap: 1500 bps) |
| Protocol fee split | `Registry` | 50% treasury / 50% buyback | Immutable constants |
| Registration deadline | `Registry.REGISTRATION_DEADLINE` | 14 days | Immutable constant |
| REFUSED→ACCEPTED lockout | `Registry.REFUSED_LOCKOUT` | 30 days | Immutable constant |
| Max claims pause | `Registry.CLAIM_PAUSE_MAX` | 72 hours | Immutable constant |
| Rotation delay | `IdentityAttestor.ROTATION_DELAY` | 7 days | Immutable constant |
| First-claim cooldown | `IdentityAttestor.FIRST_CLAIM_COOLDOWN` | 7 days | Immutable constant |
| Deposit cap | `FeeVaultFactory.defaultDepositCap` | Deploy-time env var | Timelock. Non-blocking: USDC above the cap stays in the vault uncounted (`DepositCapReached` event) and is counted once the cap is raised. |
| Buyback schedule | `BuybackModule.scheduleInterval` | 7 days | Timelock |
| Max buyback slippage | `BuybackModule.maxSlippageBps` | 100 bps (1%) | Timelock |

---

## Deployment (Arc Testnet)

### Prerequisites

- Foundry (`forge` + `cast`) installed
- `lib/forge-std` and `lib/openzeppelin-contracts` present (run `forge install`)
- All environment variables filled in (see `docs/env-example.md`)
- Deployer key imported into an encrypted Foundry keystore (never a plain env var):
  `cast wallet import nod-deployer --interactive`, then fund it from https://faucet.circle.com

### Run

```bash
forge script contracts/script/DeployNod.s.sol \
  --rpc-url https://rpc.testnet.arc.io \
  --account nod-deployer \
  --broadcast \
  --with-gas-price 20000000000 \
  -vvvv
```

The `--with-gas-price 20000000000` flag sets `maxFeePerGas` to 20 gwei, satisfying
the Arc Testnet minimum. Foundry sets `maxPriorityFeePerGas` automatically.

### Bootstrap sequence

The script executes these steps in one broadcast:

1. Deploy `NodTimelockController` — multisig is proposer + executor.
2. Deploy `FeeVaultFactory` — deployer is temporary admin.
3. Deploy `IdentityAttestor` — deployer is temporary `DEFAULT_ADMIN`.
4. Deploy `BuybackModule` — `nodToken = 0`, `disabled = true` (accumulate mode).
5. Deploy `Registry` — deployer is temporary `DEFAULT_ADMIN`.
6. Deploy `PayoutRouter`.
7. Wire: `factory.setRegistry(registry)` + grant `PAYOUT_ROUTER_ROLE` to router.
8. Whitelist `NOD_FALLBACK1` as the initial fallback recipient (set in the `Registry` constructor).
9. Hand `DEFAULT_ADMIN_ROLE` of all contracts to the timelock; deployer renounces.

After the broadcast the deployer has **no remaining privileges** on any contract.

### Post-deploy checklist (via multisig + 48h timelock)

1. `registry.setAdapterWhitelist(<BullcheeseAdapter>, true)` — enable Bullcheese.
2. `buyback.setSwapRouter(<UniswapV3Router>)` — once the router is live on Arc.
3. `buyback.setNodToken(<NOD_TOKEN_ADDRESS>)` — once the $NOD token is deployed.
4. `buyback.setDisabled(false)` — activate buybacks after steps 2 and 3.

---

## Arc USDC — Important Note

On Arc, USDC is both the native gas token (18-decimal native view) and an ERC-20
(6-decimal ERC-20 view) backed by **one** balance pool. Nod uses **only** the ERC-20
view. `FeeVault.receive()` accepts native value: it lands in the same pool and is
picked up through the ERC-20 balance, never counted twice. All accounting uses
`IERC20(USDC).balanceOf(vault)` — `address(vault).balance` is never read.

---

## Tests

```bash
# Unit + fuzz (fast)
forge test --no-match-test "invariant" -vv

# Full suite including invariants
forge test -vv

# Gas report
forge test --gas-report --no-match-test "invariant"
```

176 tests total: 171 unit/fuzz + 4 invariant suites + 1 Arc mainnet fork test (skipped
unless `ARC_MAINNET_RPC` is set).

---

## Frontend (`frontend/`)

Vite + React + wagmi/viem app to look up a token, accept or refuse it as the creator,
accept a split, claim USDC, register a new token, and verify a creator identity (link an
X, Farcaster, GitHub, TikTok or Reddit account to the wallet via the attestation service). Chains: Arc Testnet (viem's
`arcTestnet`) and a local anvil node. USDC is always shown as one balance in the
6-decimal ERC-20 view.

```bash
# 1. Local chain + contracts + a seeded demo token (anvil, chain 31337)
./scripts/dev-local.sh

# 2. Attestation service with simulated OAuth (http://localhost:8787)
./scripts/dev-attestation.sh

# 3. App (http://localhost:5173) — connect "Compte anvil #1" (creator) or "#2"
cd frontend && bun install && bun run dev

# 4. End-to-end tests against the running app (needs a freshly seeded chain)
bun run test:e2e
```

`scripts/dev-local.sh` runs `contracts/script/DevLocal.s.sol` (local only: the deployer
acts as the timelock and anvil's public keys are used), skips the 7-day first-claim
cooldown, writes addresses to `frontend/src/deployments/31337.json` and regenerates
`frontend/src/abi/`. After the Arc Testnet deployment, fill
`frontend/src/deployments/5042002.json` with the `DeployNod` addresses
(`usdc`, `registry`, `payoutRouter`, `attestor`, `factory`, plus `adapter` and `fallback`).

---

## Bullcheese integration

Bullcheese has no fee-recipient field. Each token's LP position sits in a per-token
locker (Ownable2Step), and `collectFees()` pays the creator share (75% of the 1% swap
fee) to the locker's owner. Fees come in both pool tokens: USDC on buys, the token itself
on sells.

1. The creator calls `locker.transferOwnership(predictedVault)`, using
   `FeeVaultFactory.predictVaultAddress(creator, token)`.
2. The creator calls `registerToken(...)` with the `BullcheeseAdapter`. The Registry
   deploys the vault, makes it `acceptOwnership()` of the locker, and checks that the
   vault owns it and that the pool pairs the token with USDC.
3. Anyone calls `Registry.collectFees(token)`. The USDC share is distributed like any
   other fees, and the token share waits in the vault.
4. A `KEEPER_ROLE` holder calls `swapTokenFees(token, amountIn, minUsdcOut)`. The swap
   goes through Uniswap SwapRouter02, and `minUsdcOut` must be at least the 10-minute
   TWAP value minus 3%. Call `prepareSwapOracle(token, n)` once to grow the pool's
   price history.

The vault only ever calls `acceptOwnership()` and `collectFees()` on the locker. It never
withdraws, transfers or renounces, so the liquidity stays locked for good.

Arc mainnet addresses: MintPlus `0x16D4c13aD2A23288AA9b9384F24084edC8CBeF41`,
SwapRouter02 `0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77`. Bullcheese is not deployed on
Arc Testnet.

`keeper/` runs steps 3–4 on a schedule (see `keeper/README.md`).

`contracts/test/fork/BullcheeseFork.t.sol` runs this flow against the real contracts on
an Arc mainnet fork, with real swaps through Uniswap. Only USDC is simulated there,
because Arc's USDC moves balances through a native precompile that Foundry's EVM does
not implement:

```bash
ARC_MAINNET_RPC=https://rpc.mainnet.arc.io FOUNDRY_PROFILE=fork forge test --match-path "contracts/test/fork/*"
```

---

## Attestation service (`attestation-service/`)

Links a creator's X, Farcaster, GitHub, TikTok or Reddit account to a wallet and signs
the `IdentityAttestor` attestation. See `attestation-service/README.md`.

`IdentityAttestor` rules the service relies on:
- `creatorId = creatorIdOf(keccak256(platform), externalId)`. An id is bound to its
  platform on first attestation, and attestations for another platform are rejected.
- `attest` only links a first wallet or re-confirms the same one. Changing wallets
  requires `initiateRotation` and its 7-day delay.

---

## Security

The protocol has received a **max-severity** security review covering both
rule-corpus and functional/adversary-resistance dimensions. All critical and high
findings were resolved before the test suite was written. See `docs/security-review.md`
for the full report.

Human auditors should focus on:
1. All 25 (token state × recipient state) routing combinations in `_distributeIncoming`.
2. The CREATE2 salt derivation and vault address pre-computation.
3. The 72-hour claims-pause cap enforcement in `claimsNotPausedLong`.
4. Wallet rotation delay enforcement in `IdentityAttestor`.
5. Protocol fee hard cap — `PROTOCOL_FEE_CAP` is a `constant`, not a storage variable.

---

## Out of scope (future)

- **AdvanceVault** — fee-stream advances (priority claimant on a FeeVault's stream).
  Storage and interfaces are designed to be compatible with this addition.
- Indexer / notifications.
- Mainnet deployment.
