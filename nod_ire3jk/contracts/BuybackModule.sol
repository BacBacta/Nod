// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  IUniswapV3SwapRouter (minimal)
 * @notice Minimal interface for Uniswap V3 exactInputSingle.
 */
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);
}

/**
 * @title  BuybackModule
 * @notice Accumulates USDC from protocol fees and the expired/refused routing and
 *         periodically executes a market buyback of the $NOD governance token via
 *         Uniswap V3 on Arc.  Bought tokens are sent to the dead address (0x…dEaD).
 *
 * @dev    ── Accumulate mode ──────────────────────────────────────────────────────────
 *         Until `nodToken` is set (via timelock), `executeBuyback` reverts and USDC
 *         simply accumulates.  This is the expected initial state at deployment.
 *
 *         ── Schedule ─────────────────────────────────────────────────────────────────
 *         `executeBuyback` may only be called by KEEPER_ROLE and only once per
 *         `scheduleInterval` (default 7 days).  The schedule is enforced on-chain:
 *         `nextAllowedAt` is set to `block.timestamp + scheduleInterval` after each
 *         execution.
 *
 *         ── Slippage & deadline ──────────────────────────────────────────────────────
 *         The keeper passes `amountIn` and `minAmountOut` (slippage guard) plus a
 *         `deadline` for the swap.  `minAmountOut` must exceed `amountIn *
 *         (10_000 - maxSlippageBps) / 10_000` or the call reverts — this is a
 *         second-level protection on top of Uniswap's own slippage check.
 *
 *         ── Disable switch ───────────────────────────────────────────────────────────
 *         `disabled = true` stops only the buyback swap execution.  All other
 *         contracts continue to accrue USDC into this module.  The admin (timelock)
 *         may re-enable it.
 *
 *         ── Arc USDC accounting ──────────────────────────────────────────────────────
 *         Only the USDC ERC-20 balance is used.  `address(this).balance` is never read.
 *         `receive()` reverts to prevent native value being sent here.
 */
contract BuybackModule is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NodTokenNotSet();
    error BuybackDisabledError();
    error TooEarlyForBuyback(uint256 nextAllowedAt);
    error InsufficientUsdcBalance(uint256 available, uint256 requested);
    error SlippageExceedsMax(uint256 minRequired, uint256 provided);
    error NotFromTimelock();
    error NativeNotAccepted();
    error AmountZero();

    // ─── Events ──────────────────────────────────────────────────────────────────

    event BuybackExecuted(
        uint256 usdcSpent,
        uint256 nodReceived,
        address indexed keeper,
        uint256 timestamp
    );
    event BuybackDisabledSet(bool disabled);
    event NodeTokenSet(address indexed nodToken);
    event SwapRouterSet(address indexed router);
    event ScheduleIntervalSet(uint256 interval);
    event MaxSlippageSet(uint256 maxSlippageBps);
    event PoolFeeSet(uint24 poolFee);

    // ─── Roles ───────────────────────────────────────────────────────────────────

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ─── Constants ───────────────────────────────────────────────────────────────

    /// @notice Burnt tokens are sent here.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum allowed slippage bps (50% — hard upper bound as a sanity check).
    uint256 public constant MAX_SLIPPAGE_CAP = 5000;

    // ─── Immutables ──────────────────────────────────────────────────────────────

    IERC20 public immutable USDC;
    address public immutable timelock;

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice $NOD token address.  address(0) = accumulate mode.
    address public nodToken;

    /// @notice Uniswap V3 router address on Arc.
    address public swapRouter;

    /// @notice Uniswap V3 pool fee tier for the USDC/$NOD pool.
    uint24  public poolFee;

    /// @notice Maximum slippage the keeper is allowed to pass (bps).
    uint256 public maxSlippageBps;

    /// @notice Minimum time between buyback executions (seconds).
    uint256 public scheduleInterval;

    /// @notice Earliest timestamp at which the next buyback may execute.
    uint256 public nextAllowedAt;

    /// @notice If true, `executeBuyback` reverts; USDC continues to accumulate.
    bool public disabled;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _usdc             USDC ERC-20 on Arc.
     * @param _timelock         NodTimelockController.
     * @param _swapRouter       Uniswap V3 router on Arc (may be address(0) = stub).
     * @param _poolFee          Uniswap V3 fee tier (e.g. 3000 = 0.3%).
     * @param _maxSlippageBps   Initial max slippage in bps (e.g. 100 = 1%).
     * @param _scheduleInterval Minimum seconds between buybacks (e.g. 7 days).
     * @param admin             DEFAULT_ADMIN_ROLE + KEEPER_ROLE at deploy time.
     * @param keeper            KEEPER_ROLE holder (bot).
     */
    constructor(
        address _usdc,
        address _timelock,
        address _swapRouter,
        uint24  _poolFee,
        uint256 _maxSlippageBps,
        uint256 _scheduleInterval,
        address admin,
        address keeper
    ) {
        if (_usdc == address(0) || _timelock == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        if (_maxSlippageBps > MAX_SLIPPAGE_CAP) {
            revert SlippageExceedsMax(_maxSlippageBps, MAX_SLIPPAGE_CAP);
        }

        USDC             = IERC20(_usdc);
        timelock         = _timelock;
        swapRouter       = _swapRouter;
        poolFee          = _poolFee;
        maxSlippageBps   = _maxSlippageBps;
        scheduleInterval = _scheduleInterval;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, keeper);

        // Start with buyback disabled until nodToken is set
        disabled = true;
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotFromTimelock();
        _;
    }

    // ─── Buyback execution ───────────────────────────────────────────────────────

    /**
     * @notice Execute a scheduled buyback of $NOD tokens with accumulated USDC.
     *
     * @param amountIn      USDC amount to spend (6-decimal).
     * @param minAmountOut  Minimum $NOD received (slippage guard).
     * @param deadline      Unix timestamp after which the swap reverts.
     *
     * @dev   Checks-Effects-Interactions: `nextAllowedAt` is updated BEFORE the
     *        external swap call.  If the swap reverts, the state change is also
     *        reverted, so the keeper may retry.
     */
    function executeBuyback(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant onlyRole(KEEPER_ROLE) {
        if (disabled) revert BuybackDisabledError();
        if (nodToken == address(0)) revert NodTokenNotSet();
        if (amountIn == 0) revert AmountZero();
        if (block.timestamp < nextAllowedAt) revert TooEarlyForBuyback(nextAllowedAt);

        uint256 balance = USDC.balanceOf(address(this));
        if (balance < amountIn) revert InsufficientUsdcBalance(balance, amountIn);

        // Verify keeper's minAmountOut satisfies our max-slippage constraint
        uint256 minRequired = amountIn * (10_000 - maxSlippageBps) / 10_000;
        if (minAmountOut < minRequired) revert SlippageExceedsMax(minRequired, minAmountOut);

        // Effects before interaction
        nextAllowedAt = block.timestamp + scheduleInterval;

        // Approve router (exact amount, reset after swap)
        address router = swapRouter;
        USDC.forceApprove(router, amountIn);

        uint256 nodReceived = IUniswapV3SwapRouter(router).exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn:           address(USDC),
                tokenOut:          nodToken,
                fee:               poolFee,
                recipient:         DEAD_ADDRESS,
                deadline:          deadline,
                amountIn:          amountIn,
                amountOutMinimum:  minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Zero out any remaining approval
        USDC.forceApprove(router, 0);

        emit BuybackExecuted(amountIn, nodReceived, msg.sender, block.timestamp);
    }

    // ─── Timelock-gated admin ────────────────────────────────────────────────────

    /**
     * @notice Set the $NOD token address.  Via timelock.  Non-zero only.
     *         Automatically enables the buyback (sets `disabled = false`) if it was
     *         disabled solely because nodToken was unset.
     */
    function setNodToken(address _nodToken) external onlyTimelock {
        if (_nodToken == address(0)) revert ZeroAddress();
        nodToken = _nodToken;
        // Re-enable buybacks now that the token is known
        disabled = false;
        emit NodeTokenSet(_nodToken);
        emit BuybackDisabledSet(false);
    }

    /// @notice Update the Uniswap V3 router.  Via timelock.
    function setSwapRouter(address _router) external onlyTimelock {
        if (_router == address(0)) revert ZeroAddress();
        swapRouter = _router;
        emit SwapRouterSet(_router);
    }

    /// @notice Update the pool fee tier.  Via timelock.
    function setPoolFee(uint24 _poolFee) external onlyTimelock {
        poolFee = _poolFee;
        emit PoolFeeSet(_poolFee);
    }

    /// @notice Update the maximum slippage.  Via timelock.  Bounded by MAX_SLIPPAGE_CAP.
    function setMaxSlippage(uint256 _maxSlippageBps) external onlyTimelock {
        if (_maxSlippageBps > MAX_SLIPPAGE_CAP) {
            revert SlippageExceedsMax(_maxSlippageBps, MAX_SLIPPAGE_CAP);
        }
        maxSlippageBps = _maxSlippageBps;
        emit MaxSlippageSet(_maxSlippageBps);
    }

    /// @notice Update the schedule interval.  Via timelock.
    function setScheduleInterval(uint256 _interval) external onlyTimelock {
        scheduleInterval = _interval;
        emit ScheduleIntervalSet(_interval);
    }

    /**
     * @notice Enable or disable buyback execution.  Via timelock.
     *         Disabling does NOT affect USDC accumulation in this contract.
     */
    function setDisabled(bool _disabled) external onlyTimelock {
        disabled = _disabled;
        emit BuybackDisabledSet(_disabled);
    }

    // ─── View helpers ────────────────────────────────────────────────────────────

    /// @notice USDC balance accumulated in this module (6-decimal ERC-20 view).
    function accumulatedUsdc() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    // ─── Native rejection ────────────────────────────────────────────────────────

    receive() external payable {
        revert NativeNotAccepted();
    }

    fallback() external payable {
        revert NativeNotAccepted();
    }
}
