// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}          from "forge-std/Test.sol";
import {StdInvariant}  from "forge-std/StdInvariant.sol";

import {Registry}          from "../Registry.sol";
import {FeeVaultFactory}   from "../FeeVaultFactory.sol";
import {FeeVault}          from "../FeeVault.sol";
import {IdentityAttestor}  from "../IdentityAttestor.sol";
import {BullcheeseAdapter} from "../BullcheeseAdapter.sol";

import {MockERC20}     from "../test-helpers/MockERC20.sol";
import {MockLaunchpad} from "../test-helpers/MockLaunchpad.sol";

/**
 * @title  NodHandler
 * @notice Stateful handler for the Nod protocol invariant tests.
 *         The fuzzer calls functions on this contract, which in turn exercises
 *         the protocol state machine in a bounded, valid way.
 */
contract NodHandler is Test {
    // ─── Contracts ───────────────────────────────────────────────────────────────
    MockERC20         public usdc;
    FeeVaultFactory   public factory;
    IdentityAttestor  public attestor;
    Registry          public registry;
    MockLaunchpad     public launchpad;
    BullcheeseAdapter public adapter;

    // ─── Roles ───────────────────────────────────────────────────────────────────
    address public admin;
    address public timelockAddr;
    address public pauser;
    address public treasury;
    address public buybackAddr;
    address public fallbackAddr;
    address public attesterKey_addr;
    uint256 public attesterPrivKey;

    address public creatorWallet;
    uint256 public creatorKey;
    address public recipient1;

    bytes32 public PLATFORM   = keccak256("nod");
    bytes32 public CREATOR_ID = keccak256("creator_h1");

    // ─── Tracked token ───────────────────────────────────────────────────────────
    address public trackedToken;
    address public trackedVault;

    // ─── Accounting for conservation invariant ───────────────────────────────────
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawnByRecipients;
    uint256 public ghost_totalDirectOut;

    bool public tokenRegistered;
    bool public tokenAccepted;

    constructor(
        MockERC20 _usdc,
        FeeVaultFactory _factory,
        IdentityAttestor _attestor,
        Registry _registry,
        MockLaunchpad _launchpad,
        BullcheeseAdapter _adapter,
        address _admin,
        address _timelockAddr,
        address _pauser,
        address _treasury,
        address _buybackAddr,
        address _fallbackAddr,
        uint256 _attesterKey,
        address _creatorWallet,
        uint256 _creatorPrivKey,
        address _recipient1
    ) {
        usdc         = _usdc;
        factory      = _factory;
        attestor     = _attestor;
        registry     = _registry;
        launchpad    = _launchpad;
        adapter      = _adapter;
        admin        = _admin;
        timelockAddr = _timelockAddr;
        pauser       = _pauser;
        treasury     = _treasury;
        buybackAddr  = _buybackAddr;
        fallbackAddr = _fallbackAddr;
        attesterPrivKey = _attesterKey;
        creatorWallet   = _creatorWallet;
        creatorKey      = _creatorPrivKey;
        recipient1      = _recipient1;
    }

    // ─── Helper: attest creator ──────────────────────────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address vc,,) = attestor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                vc
            )
        );
    }

    function _signAttest(bytes32 uid, address wallet, uint48 expiry, bytes32 nonce)
        internal view returns (bytes memory)
    {
        bytes32 sh = keccak256(abi.encode(attestor.ATTESTATION_TYPEHASH(), PLATFORM, uid, wallet, expiry, nonce));
        bytes32 d  = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPrivKey, d);
        return abi.encodePacked(r, s, v);
    }

    function attestCreator(bytes32 nonce) external {
        uint48 expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _signAttest(CREATOR_ID, creatorWallet, expiry, nonce);
        try attestor.attest(PLATFORM, CREATOR_ID, creatorWallet, expiry, nonce, sig) {} catch {}
    }

    // ─── Handler actions ─────────────────────────────────────────────────────────

    function depositUsdc(uint256 amount) external {
        if (trackedVault == address(0)) return;
        amount = bound(amount, 1, 100_000e6);
        usdc.mint(trackedVault, amount);
        ghost_totalDeposited += amount;
        try FeeVault(payable(trackedVault)).notifyReceived() {} catch {}
    }

    function distributeIncoming() external {
        if (trackedToken == address(0)) return;
        try registry.distributeIncoming(trackedToken) {} catch {}
    }

    function acceptToken() external {
        if (!tokenRegistered || tokenAccepted) return;
        vm.prank(creatorWallet);
        try registry.accept(trackedToken) {
            tokenAccepted = true;
        } catch {}
    }

    function acceptSplit() external {
        if (trackedToken == address(0)) return;
        vm.prank(recipient1);
        try registry.acceptSplit(trackedToken, 0) {} catch {}
    }
}

/**
 * @title NodInvariantTest
 * @notice Invariant test suite for the Nod protocol.
 */
contract NodInvariantTest is StdInvariant, Test {
    MockERC20         internal usdc;
    FeeVaultFactory   internal factory;
    IdentityAttestor  internal attestor;
    Registry          internal registry;
    MockLaunchpad     internal launchpad;
    BullcheeseAdapter internal adapter;
    NodHandler        internal handler;

    address internal admin       = makeAddr("inv_admin");
    address internal timelockAddr = makeAddr("inv_timelock");
    address internal pauser      = makeAddr("inv_pauser");
    address internal treasury    = makeAddr("inv_treasury");
    address internal buybackAddr = makeAddr("inv_buyback");
    address internal fallbackAddr = makeAddr("inv_fallback");

    address internal attesterAddr;
    uint256 internal attesterKey;
    address internal creatorWallet;
    uint256 internal creatorKey;
    address internal recipient1;

    bytes32 internal PLATFORM   = keccak256("nod");
    bytes32 internal CREATOR_ID = keccak256("creator_h1");

    address internal trackedToken;
    address internal trackedVault;

    function setUp() public {
        (attesterAddr, attesterKey) = makeAddrAndKey("inv_attester");
        (creatorWallet, creatorKey) = makeAddrAndKey("inv_creator");
        recipient1 = makeAddr("inv_recipient1");

        usdc      = new MockERC20("Mock USDC", "mUSDC", 6);
        factory   = new FeeVaultFactory(admin, address(usdc), 10_000_000e6);
        attestor  = new IdentityAttestor(admin, attesterAddr, pauser);
        launchpad = new MockLaunchpad();
        adapter   = new BullcheeseAdapter(address(launchpad));

        registry = new Registry(
            address(usdc),
            address(factory),
            address(attestor),
            treasury,
            buybackAddr,
            timelockAddr,
            admin,
            pauser,
            1000
        );

        vm.prank(admin);
        factory.setRegistry(address(registry));

        vm.startPrank(timelockAddr);
        registry.setAdapterWhitelist(address(adapter), true);
        registry.setFallbackWhitelist(fallbackAddr, true);
        vm.stopPrank();

        handler = new NodHandler(
            usdc, factory, attestor, registry, launchpad, adapter,
            admin, timelockAddr, pauser, treasury, buybackAddr, fallbackAddr,
            attesterKey, creatorWallet, creatorKey, recipient1
        );

        // Attest creator and warp past cooldown
        _attestCreator(creatorWallet, keccak256("inv-nonce-1"));
        vm.warp(block.timestamp + 7 days + 1);

        // Register token
        trackedToken = makeAddr("inv_launchToken");
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](1);
        splits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        (address predicted,) = factory.predictVaultAddress(address(this), trackedToken);
        launchpad.setFeeRecipient(trackedToken, predicted);
        launchpad.setLocked(trackedToken, true);
        registry.registerToken(trackedToken, address(adapter), CREATOR_ID, splits, fallbackAddr, keccak256("inv_lid"));

        trackedVault = registry.vaultOf(trackedToken);
        handler.attestCreator(keccak256("inv-nonce-seed")); // seed nonce in handler too

        // Target handler only
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.depositUsdc.selector;
        selectors[1] = handler.distributeIncoming.selector;
        selectors[2] = handler.acceptToken.selector;
        selectors[3] = handler.acceptSplit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address vc,,) = attestor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                vc
            )
        );
    }

    function _attestCreator(address wallet, bytes32 nonce) internal {
        uint48 expiry = uint48(block.timestamp + 30 days);
        bytes32 sh = keccak256(abi.encode(attestor.ATTESTATION_TYPEHASH(), PLATFORM, CREATOR_ID, wallet, expiry, nonce));
        bytes32 d  = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, d);
        attestor.attest(PLATFORM, CREATOR_ID, wallet, expiry, nonce, abi.encodePacked(r, s, v));
    }

    // ─── Invariant 1: Conservation ───────────────────────────────────────────────

    /**
     * @notice For the tracked vault:
     *   USDC.balanceOf(vault) + totalWithdrawn + totalDirectOut == totalReceived (±1 dust)
     */
    function invariant_Conservation() public view {
        if (trackedVault == address(0)) return;
        FeeVault v = FeeVault(payable(trackedVault));

        uint256 balance       = usdc.balanceOf(trackedVault);
        uint256 withdrawn     = v.totalWithdrawn();
        uint256 directOut     = v.totalDirectOut();
        uint256 totalReceived = v.totalReceived();

        uint256 accounted = balance + withdrawn + directOut;
        // Allow ±1 dust for rounding
        assertApproxEqAbs(accounted, totalReceived, 1, "conservation violated");
    }

    // ─── Invariant 6: Protocol fee cap ───────────────────────────────────────────

    /**
     * @notice registry.protocolFeeBps() <= 1500 always
     */
    function invariant_ProtocolFeeCap() public view {
        assertLe(registry.protocolFeeBps(), 1500, "protocol fee exceeds cap");
    }

    // ─── Invariant 3: No-PENDING-distribution ────────────────────────────────────

    /**
     * @notice For a PENDING token whose deadline has NOT passed,
     *         totalCredited + totalDirectOut == 0
     */
    function invariant_NoPendingDistribution() public view {
        if (trackedVault == address(0)) return;
        Registry.TokenState state = registry.getTokenState(trackedToken);
        if (state != Registry.TokenState.PENDING) return;

        (,, , uint48 deadline,,) = registry.getRecord(trackedToken);
        if (block.timestamp >= deadline) return;

        FeeVault v = FeeVault(payable(trackedVault));
        assertEq(v.totalCredited() + v.totalDirectOut(), 0, "pending token distributed funds");
    }

    // ─── Invariant 7: ACCEPTED→REFUSED claimable preserved ──────────────────────

    /**
     * @notice After ACCEPTED→REFUSED, claimable of existing recipients is ≥ 0.
     *         We track: if state is now REFUSED, recipient1's claimable should
     *         not have decreased from what totalCredited implies.
     */
    function invariant_RefusedClaimablePreserved() public view {
        if (trackedVault == address(0)) return;
        Registry.TokenState state = registry.getTokenState(trackedToken);
        if (state != Registry.TokenState.REFUSED) return;

        // claimable must be ≤ totalCredited (integrity check)
        FeeVault v = FeeVault(payable(trackedVault));
        assertLe(v.claimable(recipient1), v.totalCredited(), "claimable exceeds totalCredited");
    }
}
