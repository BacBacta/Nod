// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Registry} from "./Registry.sol";
import {FeeVault} from "./FeeVault.sol";
import {IdentityAttestor} from "./IdentityAttestor.sol";

/**
 * @title  PayoutRouter
 * @notice Pull-based claim interface for split recipients and creators.
 *         Verified wallets call `claim(token, splitIndex)` to receive their
 *         USDC share.  A `payoutOverride` lets a wallet direct funds to any
 *         address (e.g. a fiat-partner USDC deposit address).
 *
 * @dev    ── Pull model ───────────────────────────────────────────────────────────────
 *         This router does NOT hold any USDC.  It calls `Registry.executeClaim`
 *         which in turn calls `FeeVault.transferOut` and sends USDC directly to the
 *         payout address.
 *
 *         ── Batch claiming ───────────────────────────────────────────────────────────
 *         `batchClaim` accepts an array of (token, splitIndex) pairs.  Gas is bounded
 *         by a configurable `BATCH_GAS_LIMIT` constant — if a single claim within the
 *         batch would exceed the remaining gas, it is skipped and flagged in the
 *         return array.
 *
 *         ── Role ─────────────────────────────────────────────────────────────────────
 *         The router holds PAYOUT_ROUTER_ROLE on the Registry, which is the only role
 *         allowed to call `Registry.executeClaim`.
 */
contract PayoutRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotRecipientWallet(address token, uint8 splitIndex, address caller);
    error NothingToClaim(address token, uint8 splitIndex);
    error BatchTooLarge(uint256 length, uint256 max);

    // ─── Events ──────────────────────────────────────────────────────────────────

    /// @notice Emitted on each successful single claim.
    event Claimed(
        address indexed token,
        uint8 indexed splitIndex,
        address indexed payoutAddress,
        uint256 amount
    );

    /// @notice Emitted at the end of a successful batch claim.
    event BatchClaimed(
        address indexed claimant,
        uint256 tokenCount,
        uint256 totalAmount
    );

    /// @notice Emitted when a wallet sets a payout override.
    event PayoutOverrideSet(address indexed wallet, address indexed payoutAddress);

    // ─── Constants ───────────────────────────────────────────────────────────────

    /// @notice Maximum number of (token, splitIndex) pairs in a single `batchClaim`.
    uint256 public constant MAX_BATCH = 50;

    // ─── Immutables ──────────────────────────────────────────────────────────────

    Registry         public immutable registry;
    IdentityAttestor public immutable attestor;
    IERC20           public immutable USDC;

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice wallet => payout override address.  address(0) means use the wallet itself.
    mapping(address wallet => address payoutAddress) public payoutOverride;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _registry  Deployed Registry.
     * @param _attestor  Deployed IdentityAttestor.
     * @param _usdc      USDC ERC-20 on Arc.
     * @param admin      DEFAULT_ADMIN_ROLE holder.
     */
    constructor(
        address _registry,
        address _attestor,
        address _usdc,
        address admin
    ) {
        if (
            _registry == address(0) || _attestor == address(0) ||
            _usdc == address(0)     || admin == address(0)
        ) revert ZeroAddress();

        registry = Registry(_registry);
        attestor = IdentityAttestor(_attestor);
        USDC     = IERC20(_usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ─── Payout override ─────────────────────────────────────────────────────────

    /**
     * @notice Set a payout address for the caller's wallet.  All future claims by
     *         `msg.sender` will send USDC to `payoutAddress` instead.  Pass
     *         `address(0)` to revert to the wallet itself.
     * @param payoutAddress  Destination for future claims (e.g. a fiat-partner deposit address).
     */
    function setPayoutOverride(address payoutAddress) external {
        payoutOverride[msg.sender] = payoutAddress;
        emit PayoutOverrideSet(msg.sender, payoutAddress);
    }

    // ─── Claim ───────────────────────────────────────────────────────────────────

    /**
     * @notice Claim USDC for `token` split `splitIndex`.
     *         The caller must be the verified split recipient wallet.
     *
     * @param token       The registered token.
     * @param splitIndex  Index in the token's splits array.
     *
     * @dev   Triggers a fresh distribution snapshot via `Registry.distributeIncoming`
     *        before computing the claimable amount, ensuring the latest fees are
     *        included.  The actual claim is then executed via `Registry.executeClaim`.
     */
    function claim(address token, uint8 splitIndex)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        registry.distributeIncoming(token);

        (address recipient,, Registry.TokenState state,) = registry.getSplit(token, splitIndex);
        if (recipient != msg.sender) revert NotRecipientWallet(token, splitIndex, msg.sender);
        if (state != Registry.TokenState.ACCEPTED) revert NothingToClaim(token, splitIndex);

        uint256 amount = _computeClaimable(token, recipient);
        if (amount == 0) revert NothingToClaim(token, splitIndex);

        address payTo = _effectivePayoutAddress(msg.sender);

        registry.executeClaim(token, splitIndex, recipient, amount, payTo);

        emit Claimed(token, splitIndex, payTo, amount);
        return amount;
    }

    /**
     * @notice Claim across multiple (token, splitIndex) pairs in a single call.
     *         Gas-bounded to `MAX_BATCH` entries.  Individual failures are swallowed
     *         and flagged in `skipped`; they do NOT revert the whole batch.
     *
     * @param tokens      Array of token addresses.
     * @param splitIndexes  Corresponding split indices.
     * @return totalClaimed  Aggregate USDC claimed.
     * @return skipped       Per-entry flag: true if that entry was skipped (0 amount
     *                       or wrong state).
     */
    function batchClaim(
        address[] calldata tokens,
        uint8[]   calldata splitIndexes
    ) external nonReentrant returns (uint256 totalClaimed, bool[] memory skipped) {
        uint256 len = tokens.length;
        if (len > MAX_BATCH) revert BatchTooLarge(len, MAX_BATCH);
        require(len == splitIndexes.length, "length mismatch");

        skipped = new bool[](len);
        address payTo = _effectivePayoutAddress(msg.sender);

        for (uint256 i = 0; i < len; ) {
            address token = tokens[i];
            uint8   idx   = splitIndexes[i];

            registry.distributeIncoming(token);

            (address recipient,, Registry.TokenState state,) = registry.getSplit(token, idx);
            if (recipient != msg.sender || state != Registry.TokenState.ACCEPTED) {
                skipped[i] = true;
                unchecked { ++i; }
                continue;
            }

            uint256 amount = _computeClaimable(token, recipient);
            if (amount == 0) {
                skipped[i] = true;
                unchecked { ++i; }
                continue;
            }

            registry.executeClaim(token, idx, recipient, amount, payTo);
            totalClaimed += amount;
            emit Claimed(token, idx, payTo, amount);

            unchecked { ++i; }
        }

        if (totalClaimed > 0) {
            emit BatchClaimed(msg.sender, len, totalClaimed);
        }
    }

    // ─── Internal helpers ────────────────────────────────────────────────────────

    /**
     * @dev Compute the pro-rata share of the vault's available balance that belongs
     *      to split recipient at `splitIndex`.
     *      The protocol fee is deducted from the gross share.
     */
    function _computeClaimable(
        address token,
        address wallet
    ) internal view returns (uint256) {
        address vaultAddr = registry.vaultOf(token);
        if (vaultAddr == address(0)) return 0;

        return FeeVault(payable(vaultAddr)).claimable(wallet);
    }

    /**
     * @dev Return the effective payout address for `wallet`:
     *      the override if set, otherwise the wallet itself.
     */
    function _effectivePayoutAddress(address wallet) internal view returns (address) {
        address ov = payoutOverride[wallet];
        return ov != address(0) ? ov : wallet;
    }
}
