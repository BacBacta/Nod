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
| `BullcheeseAdapter` | `BullcheeseAdapter.sol` | Adapter for the Bullcheese launchpad. Checks that the fee recipient equals the vault AND that the fee recipient is immutably locked. |
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
| Deposit cap | `FeeVaultFactory.defaultDepositCap` | Deploy-time env var | Timelock |
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

151 tests total: 147 unit/fuzz + 4 invariant suites.

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
- Frontend / indexer / notifications.
- Mainnet deployment.
