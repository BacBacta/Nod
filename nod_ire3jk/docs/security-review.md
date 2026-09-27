# Internal security review (pre-audit)

Scope: every production contract under `contracts/` (Registry, FeeVault, FeeVaultFactory,
PayoutRouter, IdentityAttestor, BuybackModule, BullcheeseAdapter, NodTimelockController,
TwapQuote, external interfaces), full contents at commit `ecce20b`. Tests and scripts
are out of scope. This is an internal review, **not** a substitute for an external audit.
The fixes changed the contracts; the external audit must review the fixed code.

Twelve findings have a Foundry proof of concept in `docs/security-poc/NodPoC.t.sol.txt`.
Each PoC passes against the current code, which means it reproduces the bug. The file is
stored as `.txt` so it stays out of the test suite. Once a fix lands, its PoC becomes a
regression test that asserts the fixed behaviour.

## Status

All findings except 10 are fixed, each with a regression test in
`contracts/test/SecurityRegression.t.sol` (or the contract's own test file) that
replays the proof of concept and asserts the fix. Finding 10 is kept as a documented
design choice.

| # | Status | Fix | Test |
|---|---|---|---|
| 1 | Fixed | `signSplitsChange(token, proposalId)`: a signature commits to one proposal. | `test_Fix1_*` |
| 2 | Fixed | Each split's decision deadline starts when it can first be accepted: token acceptance or (re)assignment by a split change. | `test_Fix2_*` |
| 3 | Fixed | `pauseClaims` reverts while a pause runs and for 72h after one ends. | `test_Fix3_*` |
| 4 | Fixed | Credit belongs to the address: `claim` pays `claimable(caller)` whatever the split state; `splitIndex` only selects a redirect. | `test_Fix4_*` |
| 5 | Fixed | `accept`, `refuse` and split changes first settle funds under the previous state. | `test_Fix5_*` |
| 6 | Fixed | Splits expire only while the token is ACCEPTED, after their own deadline. | `test_Fix6_*` |
| 7 | Fixed | BuybackModule uses the SwapRouter02 interface; the deadline is checked in the contract. | BuybackModule tests |
| 8 | Fixed | Vault salt is `(deployer, token)`. | `test_Fix8_*` |
| 9 | Fixed | `minAmountOut` is bounded by the USDC/NOD pool's 10-minute TWAP minus `maxSlippageBps`. | `test_ExecuteBuyback_RejectsMinOutBelowTwapFloor` |
| 10 | By design | Splits pay wallets, not identities. Revocation stops the identity's creator actions (accept, refuse) and any new attestation. USDC already credited to a split wallet stays that wallet's. | — |
| 11 | Fixed | `expire` and `expireSplitRecipient` are blocked while paused and for 3 days after `unpause`. | `test_Fix11_*` |
| 12 | Fixed | `refuse` enforces the first-claim cooldown. | `test_Fix12_*` |
| 13 | Fixed | Claims try to distribute new fees but proceed if that fails; `batchClaim` skips failing entries. | `test_FixMinor_BatchClaimIsolatesFailures` |
| 14 | Fixed | `revoke` needs `REVOKER_ROLE`, granted to the multisig by `DeployNod`; `unrevoke` goes through the timelock. | `test_Fix14_*` |
| 15 | Fixed | The cap limits funds held, not lifetime inflow. It is out of the CREATE2 init code, and `Registry.setDefaultDepositCap` (timelock) changes the default. | `test_Fix15_*`, `test_DepositCap_*` |

Minor items:
- **Fixed:**
  - duplicate recipients are rejected;
  - `batchClaim` isolates failures;
  - `setNodToken` no longer re-enables buybacks;
  - `getSplit` is bounds-checked;
  - `Claimed` reports the address actually paid.
- **Open:**
  - no function lets the current wallet cancel a pending rotation; only revocation can stop it;
  - PayoutRouter's unused `attestor`, `USDC` and AccessControl remain;
  - some comments are stale.

## Checked and found sound

- **FeeVault ledger**: `totalReceived`, `totalCredited`, `totalWithdrawn`,
  `totalDirectOut` and the per-split reserves stay consistent with the real balance,
  including USDC above the deposit cap.
- **TWAP swaps**: the maths, rounding and `uint128` casts in the token-fee swap bound.
- **Bullcheese locker**: the vault accepts ownership of the locker and keeps it.

## Findings

| # | Severity | Where | Issue | PoC |
|---|---|---|---|---|
| 1 | High | Registry `signSplitsChange` | A signature does not commit to a proposal. A recipient can swap the pending proposal before the others' signatures land and take their share. Any recipient can also block every split change by re-proposing. | `SplitProposalSwap` |
| 2 | High | Registry split change | A split change resets recipients to PENDING but keeps the original 14-day deadline. After day 14, anyone can expire them at once, which freezes their credited USDC. | `SplitChangeAfterDeadlineGrief` |
| 3 | High | Registry `pauseClaims` | The pauser can re-arm the pause before each 72h window ends, so the 72h cap does not hold. | `ClaimPauseChaining` |
| 4 | High | Registry `executeClaim` | Credit belongs to an address, but it can only be claimed through an ACCEPTED split index. A recipient removed, reset or expired after being credited can never withdraw. | via 1 / 2 |
| 5 | Medium | Registry `accept` / `refuse` | Funds that arrived under the old state are not settled before the transition. An EXPIRED or REFUSED token that is later accepted gives the recipients money owed to the treasury, buyback or fallback, and the reverse happens on refuse. | `ExpiredAcceptCapturesProtocolShare`, `RefusedAcceptCapturesFallbackShare` |
| 6 | Medium | Registry `expireSplitRecipient` | Splits can be expired before the token is even accepted, for example while the creator waits out the first-claim cooldown. | `SplitsExpiredBeforeTheyCanAccept` |
| 7 | Medium | BuybackModule | It calls `exactInputSingle` with the SwapRouter v1 layout (deadline field), but Arc uses SwapRouter02, so every buyback reverts. Checked against the router's bytecode on-chain. | on-chain |
| 8 | Medium | FeeVaultFactory | The salt is `(deployer, nonce)`, so any other registration by the same deployer first makes a predicted vault undeployable. Push-model fees then sit at an empty address forever. | `NonceInvalidatesPrediction` |
| 9 | Medium | BuybackModule | The slippage guard compares NOD units with USDC units 1:1, so it either protects nothing or makes every buyback revert. | reasoning |
| 10 | Medium | PayoutRouter | Claims never check IdentityAttestor. Revoking an identity or rotating its wallet does not stop payouts to the old split wallet. | `RevokeDoesNotStopPayouts` |
| 11 | Medium | Registry `pause` | While paused, `accept`, `acceptSplit` and `refuse` are blocked, but `expire` and `expireSplitRecipient` still work and deadlines keep running. | `PauseAsymmetry` |
| 12 | Medium | Registry `refuse` | `refuse` skips the 7-day first-claim cooldown that `accept` enforces. A hijacked first attestation can refuse at once and route fees to the fallback. | `RefuseSkipsCooldown` |
| 13 | Low | PayoutRouter `claim` | Claiming first distributes new fees. If a push to the treasury, buyback or a blocklisted fallback reverts, credited balances become unclaimable. | reasoning |
| 14 | Low | IdentityAttestor `revoke` | Revocation is permanent, can target any id, and is held by the online attester key. A leaked key can lock out every creator. | reasoning |
| 15 | Low | FeeVaultFactory | The deposit cap limits lifetime inflow rather than funds held, and `defaultDepositCap` has no working setter. | reasoning |

Minor (low):
- Duplicate addresses in a split list deadlock split changes (PoC `DuplicateRecipientDeadlocksSplitsChange`).
- `batchClaim` reverts the whole batch on one bad entry, although its docs say failures are skipped (PoC `BatchClaimNotIsolated`).
- Pausing the attestor blocks every attestor action except `completeRotation`.
- `setNodToken` re-enables buybacks after an explicit `setDisabled(true)`.
- `getSplit` returns stale data for indexes past the current split count.
- The `Claimed` event reports the payout override address even when a redirect was paid.
- PayoutRouter's `attestor`, `USDC` and AccessControl are unused; some comments are stale.

## Shared root cause

Findings 2, 5, 6 and 11 come from the same design. Balances are settled lazily, so a
state change can re-route money that arrived under the old state. Deadlines are fixed
dates, not tied to when a party can first act. The fix direction is to:
- settle the vault balance at the start of every state transition;
- start each split's deadline when the token is accepted or the split is (re)assigned;
- block expiry while the Registry is paused.
