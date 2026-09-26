// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FeeVault} from "./FeeVault.sol";
import {FeeVaultFactory} from "./FeeVaultFactory.sol";
import {IdentityAttestor} from "./IdentityAttestor.sol";
import {ILaunchpadAdapter} from "./ILaunchpadAdapter.sol";
import {IUniswapV3PoolMinimal} from "./external/IUniswapV3.sol";
import {TwapQuote} from "./libraries/TwapQuote.sol";

/**
 * @title  Registry
 * @notice Core state machine for the Nod protocol.  Manages token registration,
 *         creator acceptance/refusal, split routing, protocol fees, and expiry.
 *
 * @dev    ── State machine (per token) ────────────────────────────────────────────────
 *         NONE → PENDING → ACCEPTED | REFUSED | EXPIRED
 *         ACCEPTED → REFUSED (future fees only; paid fees stay claimable)
 *         REFUSED  → ACCEPTED (after 30-day lockout)
 *         EXPIRED  → ACCEPTED (creator verifies + accepts; only future fees)
 *
 *         ── Per-recipient sub-state ──────────────────────────────────────────────────
 *         Each SplitRecipient independently follows the same 5-state machine.
 *         Token-level deadline == per-recipient deadline (simplified per Stage-1 Q1).
 *
 *         ── Fund routing table ──────────────────────────────────────────────────────
 *         Token PENDING                 → accumulate (no distribution)
 *         Token ACCEPTED + Recip ACCEPTED  → recipient (minus protocol fee)
 *         Token ACCEPTED + Recip PENDING   → accumulate
 *         Token ACCEPTED + Recip REFUSED   → fallbackRecipient
 *         Token ACCEPTED + Recip EXPIRED   → 50% treasury / 50% buyback
 *         Token REFUSED                    → fallbackRecipient
 *         Token EXPIRED                    → 50% treasury / 50% buyback
 *
 *         ── Arc USDC accounting ──────────────────────────────────────────────────────
 *         All amounts are in the USDC ERC-20 6-decimal view.  `address(this).balance`
 *         is never read.  Vaults reject native value.
 *
 *         ── Protocol fee ────────────────────────────────────────────────────────────
 *         10% of each distribution is deducted: 50% → treasury, 50% → buybackModule.
 *         Hard cap: PROTOCOL_FEE_CAP = 1500 bps (15%).  Changes behind timelock.
 *
 *         ── Pause constraints ────────────────────────────────────────────────────────
 *         PAUSER_ROLE may pause registrations, attestations (via IdentityAttestor),
 *         and buybacks.  Claims of ACCEPTED balances cannot be paused for more than
 *         72 hours — enforced by `claimPausedAt` + CLAIM_PAUSE_MAX.
 */
contract Registry is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error TokenAlreadyRegistered(address token);
    error TokenNotRegistered(address token);
    error InvalidState(address token, TokenState current, TokenState required);
    error NotCreatorWallet(address token, address expected, address got);
    error NotRecipientWallet(address token, uint8 splitIndex, address got);
    error DeadlineNotPassed(address token, uint48 deadline);
    error AdapterRejected(address token, address adapter);
    error AdapterNotWhitelisted(address adapter);
    error FallbackNotWhitelisted(address fallbackAddr);
    error InvalidSplits(string reason);
    error ProtocolFeeExceedsCap(uint16 requested, uint16 cap);
    error RefusedToAcceptedLockoutActive(address token, uint48 lockoutEnds);
    error FirstClaimCooldownActive(bytes32 creatorId, uint48 cooldownEnds);
    error ClaimsPausedTooLong();
    error NoPendingSplitChange(address token);
    error SplitChangeAlreadySigned(address token, address signer);
    error SplitChangeNotFullySigned(address token);
    error NotFromTimelock();
    /// @notice Caller does not hold PAYOUT_ROUTER_ROLE.
    error NotPayoutRouter();
    error ClaimsNotPaused();
    error NotRecipient(address token, address caller);
    error SplitIndexOutOfRange(uint8 index, uint8 length);
    error InsufficientClaimable(uint256 available, uint256 requested);
    error NoUsdcPool(address token);
    error SwapRouterNotSet();
    error MinOutBelowTwap(uint256 minOut, uint256 floor);
    error InvalidSwapAmount(uint256 amountIn);

    // ─── Events ──────────────────────────────────────────────────────────────────

    event TokenRegistered(
        address indexed token,
        address indexed vault,
        bytes32 indexed creatorId,
        address fallbackRecipient
    );
    event TokenAccepted(address indexed token, bytes32 indexed creatorId);
    event TokenRefused(address indexed token, bytes32 indexed creatorId);
    event TokenExpired(address indexed token);
    event SplitRecipientAccepted(address indexed token, uint8 splitIndex, address indexed recipient);
    event SplitRecipientRefused(address indexed token, uint8 splitIndex, address indexed recipient);
    event SplitRecipientExpired(address indexed token, uint8 splitIndex, address indexed recipient);
    event SplitsChangeProposed(address indexed token);
    event SplitsChanged(address indexed token);
    event FallbackWhitelisted(address indexed recipient, bool status);
    event AdapterWhitelisted(address indexed adapter, bool status);
    event ProtocolFeeUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BuybackModuleUpdated(address oldModule, address newModule);
    event FundsDistributed(address indexed token, address indexed vault, uint256 amount);
    event ClaimsPauseStarted(uint48 at);
    event ClaimsPauseEnded();
    event VaultDepositCapUpdated(address indexed vault, uint256 newCap);
    event RedirectSet(address indexed token, uint8 splitIndex, address indexed redirectTo);
    event SwapRouterUpdated(address oldRouter, address newRouter);
    event TokenFeesSwapped(address indexed token, uint256 tokenIn, uint256 usdcOut, uint256 twapOut);

    // ─── Enums / Types ───────────────────────────────────────────────────────────

    enum TokenState { NONE, PENDING, ACCEPTED, REFUSED, EXPIRED }

    struct SplitRecipient {
        address recipient;
        uint16  bps;            // basis points; all splits must sum to 10_000
        TokenState state;       // independent per-recipient state machine
        address redirectTo;     // optional redirect for this recipient's share
        // Signature tracking for split changes (packed with redirectTo)
        bool    hasSigned;      // whether this recipient has signed the pending change
        uint256 reserved;       // gross share held for this recipient while it is PENDING
    }

    struct TokenRecord {
        address vault;
        address adapter;
        bytes32 creatorId;          // platformUserId from IdentityAttestor
        bytes32 launchpadId;        // off-chain label / event index key
        address fallbackRecipient;  // must be whitelisted
        TokenState state;
        uint48  registeredAt;
        uint48  deadline;           // registeredAt + REGISTRATION_DEADLINE
        uint48  refusedAt;          // non-zero if ever refused
        uint8   splitCount;
        SplitRecipient[10] splits;
        // Pending splits change (guarded by all-recipients sig set)
        bool               splitChangePending;
        uint8              splitChangeSigCount;
        SplitRecipient[10] pendingSplits;
        uint8              pendingSplitCount;
        uint256            totalReserved; // sum of splits[i].reserved
    }

    // ─── Roles ───────────────────────────────────────────────────────────────────

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice May convert token-denominated fees to USDC (within the TWAP bound).
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ─── Constants ───────────────────────────────────────────────────────────────

    uint16  public constant PROTOCOL_FEE_CAP       = 1500;  // 15% hard cap
    /// @notice TWAP window used to bound token->USDC fee swaps.
    uint32  public constant SWAP_TWAP_WINDOW       = 10 minutes;
    /// @notice A swap must return at least TWAP value minus this (bps).
    uint16  public constant MAX_SWAP_SLIPPAGE_BPS  = 300;   // 3%
    uint48  public constant REGISTRATION_DEADLINE  = 14 days;
    uint48  public constant REFUSED_LOCKOUT        = 30 days;
    uint48  public constant CLAIM_PAUSE_MAX        = 72 hours;

    bytes32 public constant REASON_SPLIT      = keccak256("SPLIT_ACCEPTED");
    bytes32 public constant REASON_FALLBACK   = keccak256("FALLBACK");
    bytes32 public constant REASON_TREASURY   = keccak256("TREASURY");
    bytes32 public constant REASON_BUYBACK    = keccak256("BUYBACK");
    bytes32 public constant REASON_PROTOCOL_FEE = keccak256("PROTOCOL_FEE");

    // ─── Immutables ──────────────────────────────────────────────────────────────

    IERC20                 public immutable USDC;
    FeeVaultFactory        public immutable factory;
    IdentityAttestor       public immutable attestor;

    // ─── State ───────────────────────────────────────────────────────────────────

    address public treasury;
    address public buybackModule;

    /// @notice Uniswap SwapRouter02 used to convert token fees to USDC (0 = disabled). Via timelock.
    address public swapRouter;
    address public timelock;

    uint16  public protocolFeeBps; // default 1000 (10%)

    /// @notice Whitelist of permitted fallback recipients.
    mapping(address => bool) public whitelistedFallback;

    /// @notice Whitelist of permitted launchpad adapters.
    mapping(address => bool) public whitelistedAdapters;

    /// @notice token address => TokenRecord.
    mapping(address => TokenRecord) private _records;

    /// @notice Timestamp at which claims were paused (0 = not paused).
    uint48 public claimPausedAt;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param _usdc          USDC ERC-20 on Arc.
     * @param _factory       Deployed FeeVaultFactory.
     * @param _attestor      Deployed IdentityAttestor.
     * @param _treasury      Initial treasury address (non-zero, not a vault).
     * @param _buybackModule Deployed BuybackModule.
     * @param _timelock      NodTimelockController (becomes admin after bootstrap).
     * @param admin          Temporary admin during bootstrap (hands off to timelock).
     * @param pauser         PAUSER_ROLE holder.
     * @param _protocolFeeBps  Initial protocol fee in bps (≤ PROTOCOL_FEE_CAP).
     */
    constructor(
        address _usdc,
        address _factory,
        address _attestor,
        address _treasury,
        address _buybackModule,
        address _timelock,
        address admin,
        address pauser,
        uint16  _protocolFeeBps,
        address _initialFallback
    ) {
        if (
            _usdc == address(0) || _factory == address(0) || _attestor == address(0) ||
            _treasury == address(0) || _buybackModule == address(0) ||
            _timelock == address(0) || admin == address(0) || pauser == address(0) ||
            _initialFallback == address(0)
        ) revert ZeroAddress();
        if (_protocolFeeBps > PROTOCOL_FEE_CAP) {
            revert ProtocolFeeExceedsCap(_protocolFeeBps, PROTOCOL_FEE_CAP);
        }

        USDC          = IERC20(_usdc);
        factory       = FeeVaultFactory(_factory);
        attestor      = IdentityAttestor(_attestor);
        treasury      = _treasury;
        buybackModule = _buybackModule;
        timelock      = _timelock;
        protocolFeeBps = _protocolFeeBps;

        // setFallbackWhitelist is timelock-only, so the first fallback must be set
        // here or no token could register until a 48h timelock op executes.
        whitelistedFallback[_initialFallback] = true;
        emit FallbackWhitelisted(_initialFallback, true);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotFromTimelock();
        _;
    }

    modifier claimsNotPausedLong() {
        if (claimPausedAt != 0) {
            if (block.timestamp < uint256(claimPausedAt) + CLAIM_PAUSE_MAX) {
                revert ClaimsPausedTooLong();
            }
            claimPausedAt = 0;
            emit ClaimsPauseEnded();
        }
        _;
    }

    // ─── Registration ────────────────────────────────────────────────────────────

    /**
     * @notice Register a token with a new FeeVault and start the PENDING period.
     *
     * @param token            The launched token address.
     * @param adapter          Whitelisted ILaunchpadAdapter to verify the fee recipient.
     * @param creatorId        The creator's platformUserId (bytes32).
     * @param splits           Array of (recipient, bps) pairs. len 1–10, sum = 10_000.
     * @param fallbackRecipient Whitelisted charity/community wallet for REFUSED state.
     * @param launchpadId      Off-chain label for the originating launchpad.
     *
     * @dev   The vault is created here by the factory.  The caller's nonce determines
     *        the CREATE2 salt, so the vault address can be pre-computed off-chain.
     */
    function registerToken(
        address token,
        address adapter,
        bytes32 creatorId,
        SplitInput[] calldata splits,
        address fallbackRecipient,
        bytes32 launchpadId
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (_records[token].state != TokenState.NONE) revert TokenAlreadyRegistered(token);
        if (!whitelistedAdapters[adapter]) revert AdapterNotWhitelisted(adapter);
        if (!whitelistedFallback[fallbackRecipient]) revert FallbackNotWhitelisted(fallbackRecipient);

        _validateSplits(splits);

        // Deploy vault via factory (uses msg.sender as the deployer key for salt)
        (address vault,) = factory.deployVault(msg.sender, token);

        // Pull-model launchpads: the current owner of the fee source must already have
        // started the two-step transfer to the (predicted) vault; the vault accepts here.
        address source = ILaunchpadAdapter(adapter).feeSource(token);
        if (source != address(0)) FeeVault(payable(vault)).acceptFeeSource(source);

        // Verify fee recipient on launchpad
        if (!ILaunchpadAdapter(adapter).verifyFeeRecipient(token, vault)) {
            revert AdapterRejected(token, adapter);
        }

        // Snapshot any USDC already in the vault (e.g. fees sent before registration)
        FeeVault(payable(vault)).notifyReceived();

        // Write record
        TokenRecord storage rec = _records[token];
        rec.vault            = vault;
        rec.adapter          = adapter;
        rec.creatorId        = creatorId;
        rec.launchpadId      = launchpadId;
        rec.fallbackRecipient = fallbackRecipient;
        rec.state            = TokenState.PENDING;
        rec.registeredAt     = uint48(block.timestamp);
        rec.deadline         = uint48(block.timestamp) + REGISTRATION_DEADLINE;
        rec.splitCount       = uint8(splits.length);

        for (uint8 i = 0; i < splits.length; ) {
            rec.splits[i] = SplitRecipient({
                recipient:  splits[i].recipient,
                bps:        splits[i].bps,
                state:      TokenState.PENDING,
                redirectTo: address(0),
                hasSigned:  false,
                reserved:   0
            });
            unchecked { ++i; }
        }

        emit TokenRegistered(token, vault, creatorId, fallbackRecipient);
    }

    // Input type for splits (can't use storage struct in calldata)
    struct SplitInput {
        address recipient;
        uint16  bps;
    }

    // ─── State transitions ───────────────────────────────────────────────────────

    /**
     * @notice Accept a token.  Caller must be the creator's current verified wallet.
     *         If the token is EXPIRED (creator missed deadline), only fees received
     *         AFTER this call become claimable; accrued fees in EXPIRED state are
     *         NOT retroactively re-routed.
     * @param token  The registered token.
     */
    function accept(address token) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        address creatorWallet = _requireCreatorWallet(token, rec);

        TokenState s = rec.state;
        if (s == TokenState.ACCEPTED) {
            revert InvalidState(token, s, TokenState.PENDING);
        }
        if (s == TokenState.REFUSED) {
            // Refused → Accepted: 30-day lockout
            if (block.timestamp < uint256(rec.refusedAt) + REFUSED_LOCKOUT) {
                revert RefusedToAcceptedLockoutActive(
                    token,
                    rec.refusedAt + uint48(REFUSED_LOCKOUT)
                );
            }
        }
        // First-claim cooldown (7 days from first attestation)
        uint48 firstAt = attestor.firstAttestedAt(rec.creatorId);
        if (block.timestamp < uint256(firstAt) + IdentityAttestor(address(attestor)).FIRST_CLAIM_COOLDOWN()) {
            revert FirstClaimCooldownActive(
                rec.creatorId,
                firstAt + IdentityAttestor(address(attestor)).FIRST_CLAIM_COOLDOWN()
            );
        }

        rec.state = TokenState.ACCEPTED;
        emit TokenAccepted(token, rec.creatorId);

        // Snapshot vault balance now that state is ACCEPTED — distribute accrued fees
        // only if the token was in PENDING state (not EXPIRED — per spec, EXPIRED accrued
        // fees stay in 50/50 split and are not retroactively re-routed).
        if (s == TokenState.PENDING) {
            _distributeAccruedFees(token, rec);
        }

        (creatorWallet); // silence unused variable warning
    }

    /**
     * @notice Refuse a token.  Caller must be the creator's current verified wallet.
     *         Accrued claimable balances for ACCEPTED recipients remain claimable.
     *         Future fees route to fallbackRecipient.
     * @param token  The registered token.
     */
    function refuse(address token) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        _requireCreatorWallet(token, rec);

        TokenState s = rec.state;
        if (s != TokenState.PENDING && s != TokenState.ACCEPTED && s != TokenState.EXPIRED) {
            revert InvalidState(token, s, TokenState.PENDING);
        }

        rec.state = TokenState.REFUSED;
        rec.refusedAt = uint48(block.timestamp);
        // Shares held for PENDING recipients follow the REFUSED routing (fallback).
        _clearReserves(rec);
        emit TokenRefused(token, rec.creatorId);
    }

    /**
     * @notice Expire a token that missed its 14-day decision deadline.
     *         Anyone may call this after the deadline.
     * @param token  The registered token.
     */
    function expire(address token) external nonReentrant {
        TokenRecord storage rec = _requireRecord(token);
        if (rec.state != TokenState.PENDING) {
            revert InvalidState(token, rec.state, TokenState.PENDING);
        }
        if (block.timestamp < rec.deadline) {
            revert DeadlineNotPassed(token, rec.deadline);
        }
        rec.state = TokenState.EXPIRED;
        emit TokenExpired(token);
    }

    // ─── Per-recipient state transitions ─────────────────────────────────────────

    /**
     * @notice A split recipient accepts their share.
     *         The caller must be the recipient address for split `splitIndex`.
     *         If all recipients have now accepted, an immediate distribution is
     *         triggered from accumulated PENDING funds.
     */
    function acceptSplit(address token, uint8 splitIndex) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        _requireTokenState(token, rec, TokenState.ACCEPTED);
        SplitRecipient storage sr = _requireSplit(rec, splitIndex);
        _requireSplitRecipientCaller(token, splitIndex, sr);

        if (sr.state != TokenState.PENDING) {
            revert InvalidState(token, sr.state, TokenState.PENDING);
        }

        sr.state = TokenState.ACCEPTED;
        emit SplitRecipientAccepted(token, splitIndex, sr.recipient);

        // Release the share held while this recipient was PENDING, then distribute
        // any newly received funds.
        uint256 held = _releaseReserve(rec, sr);
        if (held > 0) _routeAcceptedShare(token, rec, FeeVault(payable(rec.vault)), sr, held);
        _distributeSingleRecipient(token, rec, splitIndex);
    }

    /**
     * @notice A split recipient refuses their share.  Future fees for this share
     *         route to the token's fallbackRecipient.
     */
    function refuseSplit(address token, uint8 splitIndex) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        _requireTokenState(token, rec, TokenState.ACCEPTED);
        SplitRecipient storage sr = _requireSplit(rec, splitIndex);
        _requireSplitRecipientCaller(token, splitIndex, sr);

        if (sr.state != TokenState.PENDING) {
            revert InvalidState(token, sr.state, TokenState.PENDING);
        }
        sr.state = TokenState.REFUSED;
        emit SplitRecipientRefused(token, splitIndex, sr.recipient);

        uint256 held = _releaseReserve(rec, sr);
        if (held > 0) {
            FeeVault(payable(rec.vault)).transferOut(rec.fallbackRecipient, held, REASON_FALLBACK);
        }
    }

    /**
     * @notice Expire a single split recipient's share after the token deadline.
     *         Anyone may call once deadline has passed and the recipient is still PENDING.
     */
    function expireSplitRecipient(address token, uint8 splitIndex) external nonReentrant {
        TokenRecord storage rec = _requireRecord(token);
        SplitRecipient storage sr = _requireSplit(rec, splitIndex);

        if (sr.state != TokenState.PENDING) {
            revert InvalidState(token, sr.state, TokenState.PENDING);
        }
        if (block.timestamp < rec.deadline) {
            revert DeadlineNotPassed(token, rec.deadline);
        }

        sr.state = TokenState.EXPIRED;
        emit SplitRecipientExpired(token, splitIndex, sr.recipient);

        uint256 held = _releaseReserve(rec, sr);
        if (held > 0) _splitProtocolFee(token, rec, FeeVault(payable(rec.vault)), held);
    }

    // ─── Splits change ───────────────────────────────────────────────────────────

    /**
     * @notice Propose a new splits configuration.  The proposer must be one of the
     *         current split recipients.  All current recipients must then call
     *         `signSplitsChange` before the change takes effect.
     * @param token        The registered token.
     * @param newSplits    The proposed new split array.
     */
    function proposeSplitsChange(
        address token,
        SplitInput[] calldata newSplits
    ) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        _requireTokenState(token, rec, TokenState.ACCEPTED);
        _validateSplits(newSplits);

        // Caller must be an existing recipient
        bool isRecipient = false;
        for (uint8 i = 0; i < rec.splitCount; ) {
            if (rec.splits[i].recipient == msg.sender) { isRecipient = true; break; }
            unchecked { ++i; }
        }
        if (!isRecipient) revert NotRecipient(token, msg.sender);

        // Reset pending
        rec.splitChangePending = true;
        rec.splitChangeSigCount = 0;
        rec.pendingSplitCount = uint8(newSplits.length);
        for (uint8 i = 0; i < rec.splitCount; ) {
            rec.splits[i].hasSigned = false;
            unchecked { ++i; }
        }
        for (uint8 i = 0; i < newSplits.length; ) {
            rec.pendingSplits[i] = SplitRecipient({
                recipient:  newSplits[i].recipient,
                bps:        newSplits[i].bps,
                state:      TokenState.PENDING,
                redirectTo: address(0),
                hasSigned:  false,
                reserved:   0
            });
            unchecked { ++i; }
        }

        emit SplitsChangeProposed(token);
    }

    /**
     * @notice Sign the pending splits change.  Must be called by each current
     *         recipient.  Once all have signed, the change is applied automatically.
     * @param token  The registered token.
     */
    function signSplitsChange(address token) external nonReentrant whenNotPaused {
        TokenRecord storage rec = _requireRecord(token);
        _requireTokenState(token, rec, TokenState.ACCEPTED);
        if (!rec.splitChangePending) revert NoPendingSplitChange(token);

        // Find and mark the caller's signature
        bool found = false;
        for (uint8 i = 0; i < rec.splitCount; ) {
            if (rec.splits[i].recipient == msg.sender) {
                if (rec.splits[i].hasSigned) revert SplitChangeAlreadySigned(token, msg.sender);
                rec.splits[i].hasSigned = true;
                unchecked { ++rec.splitChangeSigCount; }
                found = true;
                break;
            }
            unchecked { ++i; }
        }
        if (!found) revert NotRecipient(token, msg.sender);

        // If all current recipients signed, apply the change
        if (rec.splitChangeSigCount == rec.splitCount) {
            _applySplitsChange(token, rec);
        }
    }

    /**
     * @notice Allow a split recipient to redirect their own share to another address.
     *         Does not affect other recipients.
     * @param token       The registered token.
     * @param splitIndex  Index in the splits array.
     * @param redirectTo  New payout address (address(0) to clear redirect).
     */
    function setRedirect(address token, uint8 splitIndex, address redirectTo)
        external
        nonReentrant
        whenNotPaused
    {
        TokenRecord storage rec = _requireRecord(token);
        SplitRecipient storage sr = _requireSplit(rec, splitIndex);
        _requireSplitRecipientCaller(token, splitIndex, sr);

        sr.redirectTo = redirectTo;
        emit RedirectSet(token, splitIndex, redirectTo);
    }

    // ─── Distribution ────────────────────────────────────────────────────────────

    /**
     * @notice Snapshot the vault's balance and distribute any newly received USDC
     *         according to the current token state.  Callable by anyone.
     *         This is the main inbound-fee processing entry point.
     * @param token  The registered token.
     */
    function distributeIncoming(address token) external nonReentrant {
        _distributeIncoming(token);
    }

    /**
     * @notice Pull-model launchpads: collect the vault's share of fees from its fee
     *         source (e.g. the Bullcheese LP locker), then distribute. Callable by anyone.
     */
    function collectFees(address token) external nonReentrant {
        FeeVault(payable(_requireRecord(token).vault)).collectFromSource();
        _distributeIncoming(token);
    }

    /**
     * @notice Grow the token/USDC pool's price history so a TWAP over
     *         SWAP_TWAP_WINDOW becomes available. Callable by anyone (caller pays gas).
     */
    function prepareSwapOracle(address token, uint16 cardinalityNext) external {
        TokenRecord storage rec = _requireRecord(token);
        address pool = ILaunchpadAdapter(rec.adapter).usdcPool(token);
        if (pool == address(0)) revert NoUsdcPool(token);
        IUniswapV3PoolMinimal(pool).increaseObservationCardinalityNext(cardinalityNext);
    }

    /**
     * @notice Convert fees the vault received in `token` into USDC, then distribute.
     *         `minUsdcOut` comes from the keeper's quote and must be at least the TWAP
     *         value minus MAX_SWAP_SLIPPAGE_BPS, so a bad quote or a manipulated spot
     *         price cannot sell the fees cheaply. Large amounts may need several calls.
     */
    function swapTokenFees(address token, uint256 amountIn, uint256 minUsdcOut)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        TokenRecord storage rec = _requireRecord(token);
        address router = swapRouter;
        if (router == address(0)) revert SwapRouterNotSet();
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(ILaunchpadAdapter(rec.adapter).usdcPool(token));
        if (address(pool) == address(0)) revert NoUsdcPool(token);

        if (amountIn == 0 || amountIn > type(uint128).max) revert InvalidSwapAmount(amountIn);
        uint256 twapOut = TwapQuote.quote(pool, SWAP_TWAP_WINDOW, token, address(USDC), uint128(amountIn));
        uint256 floor = (twapOut * (10_000 - MAX_SWAP_SLIPPAGE_BPS)) / 10_000;
        if (minUsdcOut < floor) revert MinOutBelowTwap(minUsdcOut, floor);

        uint256 out = FeeVault(payable(rec.vault)).swapTokenFees(router, pool.fee(), amountIn, minUsdcOut);
        emit TokenFeesSwapped(token, amountIn, out, twapOut);
        _distributeIncoming(token);
    }

    function _distributeIncoming(address token) internal {
        TokenRecord storage rec = _requireRecord(token);
        FeeVault vault = FeeVault(payable(rec.vault));

        // Snapshot first
        vault.notifyReceived();

        TokenState s = rec.state;
        if (s == TokenState.PENDING) return; // accumulate

        uint256 available = _distributable(rec, vault);
        if (available == 0) return;

        if (s == TokenState.REFUSED) {
            _distributeAllToFallback(token, rec, vault, available);
        } else if (s == TokenState.EXPIRED) {
            _distributeAllExpired(token, rec, vault, available);
        } else if (s == TokenState.ACCEPTED) {
            _distributeAccepted(token, rec, vault, available);
        }
    }

    /**
     * @notice Distribute EXPIRED-state accrued fees (50/50 treasury/buyback).
     *         Callable by anyone.  Safe to call repeatedly; only distributes what
     *         is actually available.
     * @param token  The registered token.
     */
    function distributeExpired(address token) external nonReentrant {
        TokenRecord storage rec = _requireRecord(token);
        if (rec.state != TokenState.EXPIRED) {
            revert InvalidState(token, rec.state, TokenState.EXPIRED);
        }
        FeeVault vault = FeeVault(payable(rec.vault));
        vault.notifyReceived();
        uint256 available = _distributable(rec, vault);
        if (available == 0) return;
        _distributeAllExpired(token, rec, vault, available);
    }

    // ─── Claim (via PayoutRouter) ────────────────────────────────────────────────

    /**
     * @notice Called by PayoutRouter to transfer claimable USDC directly from the
     *         vault to `recipient`.  All routing validation is done in the router.
     *
     * @dev    This function exists so the router doesn't need direct access to the
     *         vault address.  The Registry is the single point of vault control.
     *
     * @param token      The registered token.
     * @param splitIndex The split index being claimed.
     * @param recipient  Ultimate payout destination (may differ from split address
     *                   if a payout override or redirect is set).
     * @param amount     Amount to transfer.
     */
    function executeClaim(
        address token,
        uint8   splitIndex,
        address recipient,
        uint256 amount,
        address payTo
    ) external nonReentrant claimsNotPausedLong {
        // Only the PayoutRouter may call this
        // NOTE: PayoutRouter is not set as an immutable here to avoid circular
        // dependency at deploy time. We use a role instead.
        if (!hasRole(keccak256("PAYOUT_ROUTER_ROLE"), msg.sender)) {
            revert NotPayoutRouter();
        }

        TokenRecord storage rec = _requireRecord(token);
        SplitRecipient storage sr = _requireSplit(rec, splitIndex);

        if (sr.recipient != recipient) {
            revert NotRecipientWallet(token, splitIndex, recipient);
        }
        if (sr.state != TokenState.ACCEPTED) {
            revert InvalidState(token, sr.state, TokenState.ACCEPTED);
        }

        FeeVault vault = FeeVault(payable(rec.vault));
        uint256 availableClaimable = vault.claimable(recipient);
        if (amount > availableClaimable) {
            revert InsufficientClaimable(availableClaimable, amount);
        }

        address payout = (sr.redirectTo != address(0)) ? sr.redirectTo : payTo;

        vault.withdrawFor(recipient, payout, amount);
        emit FundsDistributed(token, rec.vault, amount);
    }

    // ─── Pausing ─────────────────────────────────────────────────────────────────

    /**
     * @notice Pause registrations and general state transitions.
     *         Does NOT immediately pause claims — see `pauseClaims`.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume registrations and state transitions.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Start the claims-pause window (max 72 h).  Only PAUSER_ROLE.
     */
    function pauseClaims() external onlyRole(PAUSER_ROLE) {
        claimPausedAt = uint48(block.timestamp);
        emit ClaimsPauseStarted(claimPausedAt);
    }

    /**
     * @notice End the claims-pause window early.  Only PAUSER_ROLE.
     */
    function unpauseClaims() external onlyRole(PAUSER_ROLE) {
        if (claimPausedAt == 0) revert ClaimsNotPaused();
        claimPausedAt = 0;
        emit ClaimsPauseEnded();
    }

    // ─── Timelock-gated admin ─────────────────────────────────────────────────────

    /// @notice Update the protocol fee.  Bounded by PROTOCOL_FEE_CAP.  Via timelock.
    function setProtocolFee(uint16 newBps) external onlyTimelock {
        if (newBps > PROTOCOL_FEE_CAP) revert ProtocolFeeExceedsCap(newBps, PROTOCOL_FEE_CAP);
        uint16 old = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeUpdated(old, newBps);
    }

    /// @notice Update the treasury address.  Via timelock.
    function setTreasury(address newTreasury) external onlyTimelock {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Set the Uniswap router used for token-fee swaps (0 disables).  Via timelock.
    function setSwapRouter(address newRouter) external onlyTimelock {
        address old = swapRouter;
        swapRouter = newRouter;
        emit SwapRouterUpdated(old, newRouter);
    }

    /// @notice Update the BuybackModule address.  Via timelock.
    function setBuybackModule(address newModule) external onlyTimelock {
        if (newModule == address(0)) revert ZeroAddress();
        address old = buybackModule;
        buybackModule = newModule;
        emit BuybackModuleUpdated(old, newModule);
    }

    /// @notice Whitelist or de-list a fallback recipient.  Via timelock.
    function setFallbackWhitelist(address recipient, bool status) external onlyTimelock {
        if (recipient == address(0)) revert ZeroAddress();
        whitelistedFallback[recipient] = status;
        emit FallbackWhitelisted(recipient, status);
    }

    /// @notice Whitelist or de-list a launchpad adapter.  Via timelock.
    function setAdapterWhitelist(address adapter, bool status) external onlyTimelock {
        if (adapter == address(0)) revert ZeroAddress();
        whitelistedAdapters[adapter] = status;
        emit AdapterWhitelisted(adapter, status);
    }

    /// @notice Update the deposit cap on an individual vault.  Via timelock.
    function setVaultDepositCap(address vault, uint256 newCap) external onlyTimelock {
        FeeVault(payable(vault)).setDepositCap(newCap);
        emit VaultDepositCapUpdated(vault, newCap);
    }

    // ─── View helpers ────────────────────────────────────────────────────────────

    /// @notice Return the raw TokenRecord state for `token`.
    function getTokenState(address token) external view returns (TokenState) {
        return _records[token].state;
    }

    /// @notice Return the vault address for `token` (address(0) if unregistered).
    function vaultOf(address token) external view returns (address) {
        return _records[token].vault;
    }

    /// @notice Return the split count for `token`.
    function splitCountOf(address token) external view returns (uint8) {
        return _records[token].splitCount;
    }

    /// @notice Return the split recipient data at index `i` for `token`.
    function getSplit(address token, uint8 i)
        external
        view
        returns (address recipient, uint16 bps, TokenState state, address redirectTo)
    {
        TokenRecord storage rec = _records[token];
        SplitRecipient storage sr = rec.splits[i];
        return (sr.recipient, sr.bps, sr.state, sr.redirectTo);
    }

    /// @notice Gross USDC held for split `i` of `token` while that recipient is PENDING.
    function reservedOf(address token, uint8 i) external view returns (uint256) {
        return _records[token].splits[i].reserved;
    }

    /// @notice Return full record for `token` (core fields, not splits array).
    function getRecord(address token)
        external
        view
        returns (
            address vault,
            bytes32 creatorId,
            TokenState state,
            uint48  deadline,
            uint48  registeredAt,
            address fallbackRecipient
        )
    {
        TokenRecord storage rec = _records[token];
        return (
            rec.vault,
            rec.creatorId,
            rec.state,
            rec.deadline,
            rec.registeredAt,
            rec.fallbackRecipient
        );
    }

    // ─── Internal helpers ────────────────────────────────────────────────────────

    function _requireRecord(address token)
        internal
        view
        returns (TokenRecord storage rec)
    {
        rec = _records[token];
        if (rec.state == TokenState.NONE) revert TokenNotRegistered(token);
    }

    function _requireTokenState(
        address token,
        TokenRecord storage rec,
        TokenState required
    ) internal view {
        if (rec.state != required) revert InvalidState(token, rec.state, required);
    }

    function _requireCreatorWallet(address token, TokenRecord storage rec)
        internal
        view
        returns (address wallet)
    {
        wallet = attestor.walletOf(rec.creatorId);
        if (wallet == address(0) || wallet != msg.sender) {
            revert NotCreatorWallet(token, wallet, msg.sender);
        }
    }

    function _requireSplit(TokenRecord storage rec, uint8 index)
        internal
        view
        returns (SplitRecipient storage sr)
    {
        if (index >= rec.splitCount) revert SplitIndexOutOfRange(index, rec.splitCount);
        sr = rec.splits[index];
    }

    function _requireSplitRecipientCaller(
        address token,
        uint8 index,
        SplitRecipient storage sr
    ) internal view {
        if (sr.recipient != msg.sender) {
            revert NotRecipientWallet(token, index, msg.sender);
        }
    }

    function _validateSplits(SplitInput[] calldata splits) internal pure {
        if (splits.length == 0 || splits.length > 10) {
            revert InvalidSplits("length 1-10 required");
        }
        uint256 total;
        for (uint256 i = 0; i < splits.length; ) {
            if (splits[i].recipient == address(0)) revert InvalidSplits("zero recipient");
            total += splits[i].bps;
            unchecked { ++i; }
        }
        if (total != 10_000) revert InvalidSplits("bps must sum to 10000");
    }

    function _applySplitsChange(address token, TokenRecord storage rec) internal {
        // Every current recipient signed the change, so shares held for PENDING
        // recipients return to the pool and are distributed under the new splits.
        _clearReserves(rec);
        uint8 newCount = rec.pendingSplitCount;
        rec.splitCount = newCount;
        for (uint8 i = 0; i < newCount; ) {
            rec.splits[i] = rec.pendingSplits[i];
            unchecked { ++i; }
        }
        rec.splitChangePending = false;
        rec.splitChangeSigCount = 0;
        emit SplitsChanged(token);
    }

    /**
     * @dev Distribute all available vault funds to the fallback recipient.
     *      No protocol fee is taken from REFUSED flows (per spec — "fallback" is
     *      a whitelisted charity; protocol should not skim charity funds).
     */
    function _distributeAllToFallback(
        address token,
        TokenRecord storage rec,
        FeeVault vault,
        uint256 amount
    ) internal {
        vault.transferOut(rec.fallbackRecipient, amount, REASON_FALLBACK);
        emit FundsDistributed(token, address(vault), amount);
    }

    /**
     * @dev Distribute all available vault funds 50/50 to treasury and buyback.
     *      Protocol fee NOT separately taken — the entire amount is split here.
     */
    function _distributeAllExpired(
        address token,
        TokenRecord storage rec,
        FeeVault vault,
        uint256 amount
    ) internal {
        uint256 half = amount / 2;
        uint256 remainder = amount - half; // handles odd amounts (remainder → treasury)

        if (half > 0) {
            vault.transferOut(buybackModule, half, REASON_BUYBACK);
        }
        if (remainder > 0) {
            vault.transferOut(treasury, remainder, REASON_TREASURY);
        }
        emit FundsDistributed(token, address(vault), amount);
        (rec); // silence unused warning
    }

    /**
     * @dev Distribute incoming funds across all split recipients according to their
     *      individual states.  Protocol fee (10%) is taken from each ACCEPTED
     *      recipient's share before transfer.
     */
    function _distributeAccepted(
        address token,
        TokenRecord storage rec,
        FeeVault vault,
        uint256 available
    ) internal {
        uint8 count = rec.splitCount;

        for (uint8 i = 0; i < count; ) {
            SplitRecipient storage sr = rec.splits[i];
            uint256 gross = (available * sr.bps) / 10_000;
            if (i == 0) gross = available - _sumOtherShares(available, rec, count);

            if (gross == 0) {
                unchecked { ++i; }
                continue;
            }

            TokenState srState = sr.state;

            if (srState == TokenState.ACCEPTED) {
                _routeAcceptedShare(token, rec, vault, sr, gross);
            } else if (srState == TokenState.PENDING) {
                // Hold the share until the recipient accepts, refuses or expires.
                sr.reserved += gross;
                rec.totalReserved += gross;
            } else if (srState == TokenState.REFUSED) {
                vault.transferOut(rec.fallbackRecipient, gross, REASON_FALLBACK);
            } else if (srState == TokenState.EXPIRED) {
                uint256 half = gross / 2;
                uint256 rem  = gross - half;
                if (half > 0) vault.transferOut(buybackModule, half, REASON_BUYBACK);
                if (rem  > 0) vault.transferOut(treasury, rem, REASON_TREASURY);
            }

            unchecked { ++i; }
        }
        emit FundsDistributed(token, address(vault), available);
    }

    /// @dev Route an ACCEPTED recipient's gross share: protocol fee out, net credited.
    function _routeAcceptedShare(
        address token,
        TokenRecord storage rec,
        FeeVault vault,
        SplitRecipient storage sr,
        uint256 gross
    ) internal {
        uint256 fee = (gross * protocolFeeBps) / 10_000;
        uint256 net = gross - fee;
        if (fee > 0) _splitProtocolFee(token, rec, vault, fee);
        if (net > 0) vault.credit(sr.recipient, net);
    }

    /// @dev Vault funds not yet credited and not held for PENDING recipients.
    function _distributable(TokenRecord storage rec, FeeVault vault)
        internal
        view
        returns (uint256)
    {
        uint256 available = vault.availableBalance();
        uint256 held = rec.totalReserved;
        return available > held ? available - held : 0;
    }

    /// @dev Zero `sr.reserved` and return the amount that was held.
    function _releaseReserve(TokenRecord storage rec, SplitRecipient storage sr)
        internal
        returns (uint256 held)
    {
        held = sr.reserved;
        if (held == 0) return 0;
        sr.reserved = 0;
        rec.totalReserved -= held;
    }

    /// @dev Release every held share back to the undistributed pool.
    function _clearReserves(TokenRecord storage rec) internal {
        if (rec.totalReserved == 0) return;
        for (uint8 i = 0; i < rec.splitCount; ) {
            rec.splits[i].reserved = 0;
            unchecked { ++i; }
        }
        rec.totalReserved = 0;
    }

    /// @dev Sum shares for recipients at indices 1..count-1 (to compute dust for index 0).
    function _sumOtherShares(
        uint256 available,
        TokenRecord storage rec,
        uint8 count
    ) internal view returns (uint256 sum) {
        for (uint8 i = 1; i < count; ) {
            sum += (available * rec.splits[i].bps) / 10_000;
            unchecked { ++i; }
        }
    }

    function _splitProtocolFee(
        address token,
        TokenRecord storage rec,
        FeeVault vault,
        uint256 fee
    ) internal {
        uint256 half = fee / 2;
        uint256 rem  = fee - half;
        if (half > 0) vault.transferOut(buybackModule, half, REASON_BUYBACK);
        if (rem  > 0) vault.transferOut(treasury, rem, REASON_TREASURY);
        (token); (rec); // silence unused warnings
    }

    /**
     * @dev Distribute accrued fees when a PENDING token transitions to ACCEPTED.
     *      Only ACCEPTED recipients at the time of call receive their share;
     *      others follow their own routing rules.
     */
    function _distributeAccruedFees(address token, TokenRecord storage rec) internal {
        FeeVault vault = FeeVault(payable(rec.vault));
        vault.notifyReceived(); // count fees that arrived since the last snapshot
        uint256 available = _distributable(rec, vault);
        if (available == 0) return;
        _distributeAccepted(token, rec, vault, available);
    }

    /**
     * @dev Try to distribute any accrued vault balance for a single recipient that
     *      just accepted.
     */
    function _distributeSingleRecipient(
        address token,
        TokenRecord storage rec,
        uint8 /* splitIndex */
    ) internal {
        // Re-run full distribution — simpler and safer than partial distribution
        FeeVault vault = FeeVault(payable(rec.vault));
        vault.notifyReceived(); // count fees that arrived since the last snapshot
        uint256 available = _distributable(rec, vault);
        if (available == 0) return;
        _distributeAccepted(token, rec, vault, available);
    }
}
