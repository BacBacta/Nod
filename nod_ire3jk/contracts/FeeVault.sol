// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  FeeVault
 * @notice Per-token, non-upgradeable USDC accumulation vault deployed by FeeVaultFactory
 *         via CREATE2.  The vault address can be computed deterministically BEFORE the
 *         token exists, allowing launchpads to register it as a fee recipient at token
 *         creation time.
 *
 * @dev    ── Arc USDC dual-view rule ──────────────────────────────────────────────────
 *         On Arc, USDC is simultaneously the native gas token (18-decimal native view)
 *         and an ERC-20 (6-decimal ERC-20 view), backed by ONE balance pool.  This
 *         contract uses ONLY the ERC-20 view for all accounting:
 *           • All balances are tracked via ERC-20 transfer deltas (balanceOf snapshots).
 *           • `receive()` explicitly reverts — no native value must ever be sent here.
 *           • `address(this).balance` is never read, written, or used in any calculation.
 *
 *         ── Fund-movement restriction ────────────────────────────────────────────────
 *         The only address that may move funds out of this vault is the Registry (via
 *         `transferOut`).  The Registry validates all routing decisions (state machine,
 *         split recipients, fallback, treasury, buyback) before calling.  No other
 *         withdrawal path exists.
 *
 *         ── AdvanceVault compatibility ───────────────────────────────────────────────
 *         A `priorityClaimHook` slot is reserved in storage (currently address(0)) so
 *         an AdvanceVault can later be wired as a priority claimant without a storage
 *         layout migration.
 */
contract FeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 internal constant REASON_SPLIT = keccak256("SPLIT_ACCEPTED");

    // ─── Errors ──────────────────────────────────────────────────────────────────

    /// @notice Native USDC must never be sent to this vault.
    error NativeNotAccepted();
    /// @notice Caller is not the authorised Registry.
    error NotRegistry();
    /// @notice Transfer amount exceeds the vault's current ERC-20 balance.
    error InsufficientBalance(uint256 available, uint256 requested);
    /// @notice Recipient has insufficient accrued claimable balance.
    error InsufficientClaimable(uint256 available, uint256 requested);
    /// @notice Deposit would exceed the per-vault beta cap.
    error DepositCapExceeded(uint256 cap, uint256 wouldBe);
    /// @notice Zero-address argument where a non-zero address is required.
    error ZeroAddress();

    // ─── Events ──────────────────────────────────────────────────────────────────

    /// @notice Emitted when a USDC deposit delta is recorded.
    event FeeReceived(address indexed vault, uint256 amount);

    /// @notice Emitted when funds are transferred out by the Registry.
    event FundsTransferred(address indexed to, uint256 amount, bytes32 indexed reason);

    // ─── Immutables ──────────────────────────────────────────────────────────────

    /// @notice USDC ERC-20 address on Arc (6 decimals).
    IERC20 public immutable USDC;

    /// @notice Factory that deployed this vault.
    address public immutable factory;

    /// @notice The launchpad token this vault serves.
    address public immutable token;

    /// @notice The CREATE2 salt used to deploy this vault.
    bytes32 public immutable salt;

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice The Registry contract authorised to call `transferOut` and
    ///         `notifyReceived`.
    address public registry;

    /// @notice Cumulative USDC received by this vault (ERC-20 units, 6 decimals).
    uint256 public totalReceived;

    /// @notice Cumulative USDC committed to split recipients via `credit`.
    uint256 public totalCredited;

    /// @notice Cumulative USDC physically withdrawn via `withdrawFor`.
    uint256 public totalWithdrawn;

    /// @notice Cumulative USDC transferred directly out by `transferOut` (non-split paths).
    uint256 public totalDirectOut;

    /// @notice Accrued claimable amount per split recipient.
    mapping(address recipient => uint256 amount) public claimable;

    /// @notice Current per-vault deposit cap (0 = no cap, only enforced if > 0).
    uint256 public depositCap;

    /**
     * @notice Reserved slot for a future AdvanceVault priority-claimant hook.
     *         Do not read or write this from any current code path.
     */
    address public priorityClaimHook; // reserved — always address(0) for now

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _usdc      USDC ERC-20 address.
     * @param _factory   Address of the deploying FeeVaultFactory.
     * @param _token     Launchpad token this vault serves.
     * @param _salt      The CREATE2 salt used to deploy this vault (stored for off-chain
     *                   verification).
     * @param _depositCap  Initial per-vault deposit cap in USDC (6-decimal units).
     *                     Pass 0 to disable the cap at deploy time.
     */
    constructor(
        address _usdc,
        address _factory,
        address _token,
        bytes32 _salt,
        uint256 _depositCap
    ) {
        if (_usdc == address(0) || _factory == address(0) || _token == address(0)) {
            revert ZeroAddress();
        }
        USDC = IERC20(_usdc);
        factory = _factory;
        token = _token;
        salt = _salt;
        depositCap = _depositCap;
    }

    // ─── Registry registration (one-time) ────────────────────────────────────────

    /**
     * @notice Wire this vault to its Registry.  Called once by FeeVaultFactory
     *         immediately after CREATE2 deployment.  Cannot be changed afterward.
     * @param _registry  Address of the Registry contract.
     */
    function setRegistry(address _registry) external {
        if (msg.sender != factory) revert NotRegistry();
        if (_registry == address(0)) revert ZeroAddress();
        if (registry != address(0)) revert NotRegistry(); // already set
        registry = _registry;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    // ─── Accounting ──────────────────────────────────────────────────────────────

    /**
     * @notice Snapshot the current ERC-20 balance and credit any positive delta as new
     *         fees received.
     *
     * @dev    `totalReceived` tracks cumulative inbound USDC and is derived from the
     *         current balance plus all previously observed outflows.
     */
    function notifyReceived() external nonReentrant {
        uint256 balance = USDC.balanceOf(address(this));
        uint256 observedOut = totalWithdrawn + totalDirectOut;
        uint256 accounted = totalReceived;
        uint256 currentGross = balance + observedOut;
        if (currentGross <= accounted) return;

        uint256 delta;
        unchecked {
            delta = currentGross - accounted;
        }

        if (depositCap > 0 && totalReceived + delta > depositCap) {
            revert DepositCapExceeded(depositCap, totalReceived + delta);
        }

        totalReceived += delta;
        emit FeeReceived(address(this), delta);
    }

    /**
     * @notice Update the deposit cap.  Only the Registry (which validates timelock
     *         governance) may call this.
     * @param newCap  New cap in USDC (6-decimal).  Pass 0 to remove the cap.
     */
    function setDepositCap(uint256 newCap) external onlyRegistry {
        depositCap = newCap;
    }

    // ─── Fund movement (Registry-only) ───────────────────────────────────────────

    /**
     * @notice Credit accrued entitlement for `recipient` without moving USDC.
     *         Only callable by Registry.
     */
    function credit(address recipient, uint256 amount) external onlyRegistry {
        if (recipient == address(0)) revert ZeroAddress();
        claimable[recipient] += amount;
        totalCredited += amount;
    }

    /**
     * @notice Withdraw claimable USDC for `recipient` to `payTo`.
     *         Only callable by Registry.
     */
    function withdrawFor(address recipient, address payTo, uint256 amount)
        external
        nonReentrant
        onlyRegistry
    {
        uint256 availableClaim = claimable[recipient];
        if (amount > availableClaim) {
            revert InsufficientClaimable(availableClaim, amount);
        }

        claimable[recipient] = availableClaim - amount;
        totalWithdrawn += amount;

        USDC.safeTransfer(payTo, amount);
        emit FundsTransferred(payTo, amount, REASON_SPLIT);
    }

    /**
     * @notice Transfer `amount` USDC to `to`.  Only the Registry may call this after
     *         validating all routing rules.
     */
    function transferOut(address to, uint256 amount, bytes32 reason)
        external
        nonReentrant
        onlyRegistry
    {
        uint256 available = USDC.balanceOf(address(this));
        if (amount > available) revert InsufficientBalance(available, amount);

        totalDirectOut += amount;

        USDC.safeTransfer(to, amount);
        emit FundsTransferred(to, amount, reason);
    }

    // ─── View helpers ────────────────────────────────────────────────────────────

    /**
     * @notice Current uncommitted USDC balance in this vault (ERC-20 view).
     */
    function availableBalance() external view returns (uint256) {
        uint256 lockedForRecipients = totalCredited - totalWithdrawn;
        uint256 balance = USDC.balanceOf(address(this));
        return balance > lockedForRecipients ? balance - lockedForRecipients : 0;
    }

    // ─── Native ETH / USDC rejection ─────────────────────────────────────────────

    /// @dev On Arc, native value is USDC — explicitly reject to prevent double-counting.
    receive() external payable {
        revert NativeNotAccepted();
    }

    /// @dev Fallback also rejects native value (not payable so casts from plain address work).
    fallback() external {
        revert NativeNotAccepted();
    }
}
