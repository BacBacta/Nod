// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Registry}          from "../Registry.sol";
import {FeeVaultFactory}   from "../FeeVaultFactory.sol";
import {FeeVault}          from "../FeeVault.sol";
import {IdentityAttestor}  from "../IdentityAttestor.sol";
import {MockLaunchpadAdapter} from "../test-helpers/MockLaunchpadAdapter.sol";

import {MockERC20}     from "../test-helpers/MockERC20.sol";
import {MockLaunchpad} from "../test-helpers/MockLaunchpad.sol";

/**
 * @title  RegistryTest
 * @notice Comprehensive unit tests for Registry.sol — state machine, splits,
 *         protocol fees, pausing, and distribution flows.
 */
contract RegistryTest is Test {
    // ─── Contracts ───────────────────────────────────────────────────────────────
    MockERC20         internal usdc;
    FeeVaultFactory   internal factory;
    IdentityAttestor  internal attestor;
    Registry          internal registry;
    MockLaunchpad     internal launchpad;
    MockLaunchpadAdapter internal adapter;

    // ─── Addresses ───────────────────────────────────────────────────────────────
    address internal admin       = makeAddr("admin");
    address internal timelockAddr = makeAddr("timelock"); // acts as timelock in tests
    address internal pauser      = makeAddr("pauser");
    address internal treasury    = makeAddr("treasury");
    address internal buyback     = makeAddr("buyback");
    address internal fallbackAddr = makeAddr("fallback");
    address internal attesterAddr;
    uint256 internal attesterKey;

    // ─── Creator / recipient addresses + keys ────────────────────────────────────
    address internal creatorWallet;
    uint256 internal creatorKey;
    address internal recipient1;
    address internal recipient2;

    bytes32 internal PLATFORM      = keccak256("nod");
    bytes32 internal CREATOR_ID    = keccak256("creator1");

    uint16  internal constant FEE_BPS = 1000; // 10%

    // ─── Token for tests ────────────────────────────────────────────────────────
    address internal launchToken = makeAddr("launchToken");

    function setUp() public {
        // Keys
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        (creatorWallet, creatorKey) = makeAddrAndKey("creatorWallet");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");

        // Contracts
        usdc      = new MockERC20("Mock USDC", "mUSDC", 6);
        factory   = new FeeVaultFactory(admin, address(usdc), 1_000_000e6);
        attestor  = new IdentityAttestor(admin, attesterAddr, pauser);
        launchpad = new MockLaunchpad();
        adapter   = new MockLaunchpadAdapter(address(launchpad));

        registry = new Registry(
            address(usdc),
            address(factory),
            address(attestor),
            treasury,
            buyback,
            timelockAddr,
            admin,
            pauser,
            FEE_BPS,
            fallbackAddr
        );

        // Wire factory → registry
        vm.prank(admin);
        factory.setRegistry(address(registry));

        // Whitelist adapter + fallback via timelock
        vm.startPrank(timelockAddr);
        registry.setAdapterWhitelist(address(adapter), true);
        registry.setFallbackWhitelist(fallbackAddr, true);
        vm.stopPrank();

        // Attest creator
        _attestCreator(creatorWallet, keccak256("nonce-creator"));

        // Warp past 7-day cooldown
        vm.warp(block.timestamp + 7 days + 1);
    }

    // ─── EIP-712 helper ──────────────────────────────────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,
        ) = attestor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signAttest(
        bytes32 platformUserId,
        address wallet,
        uint48  expiry,
        bytes32 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                attestor.ATTESTATION_TYPEHASH(),
                PLATFORM,
                platformUserId,
                wallet,
                expiry,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _attestCreator(address wallet, bytes32 nonce) internal {
        uint48 expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _signAttest(CREATOR_ID, wallet, expiry, nonce);
        attestor.attest(PLATFORM, CREATOR_ID, wallet, expiry, nonce, sig);
    }

    // ─── Registration helper ─────────────────────────────────────────────────────

    function _makeSplits1(address recip) internal pure returns (Registry.SplitInput[] memory) {
        Registry.SplitInput[] memory s = new Registry.SplitInput[](1);
        s[0] = Registry.SplitInput({recipient: recip, bps: 10_000});
        return s;
    }

    function _makeSplits2(address r1, address r2) internal pure returns (Registry.SplitInput[] memory) {
        Registry.SplitInput[] memory s = new Registry.SplitInput[](2);
        s[0] = Registry.SplitInput({recipient: r1, bps: 5000});
        s[1] = Registry.SplitInput({recipient: r2, bps: 5000});
        return s;
    }

    function _registerToken(address tkn, Registry.SplitInput[] memory splits) internal returns (address vault) {
        // The launchpad vault prediction: factory.predictVaultAddress(msg.sender, token)
        (address predicted,) = factory.predictVaultAddress(address(this), tkn);
        launchpad.setFeeRecipient(tkn, predicted);
        launchpad.setLocked(tkn, true);

        registry.registerToken(
            tkn,
            address(adapter),
            CREATOR_ID,
            splits,
            fallbackAddr,
            keccak256("launchpadId")
        );
        vault = registry.vaultOf(tkn);
    }

    function _registerAndAccept(address tkn, Registry.SplitInput[] memory splits) internal returns (address vault) {
        vault = _registerToken(tkn, splits);

        vm.prank(creatorWallet);
        registry.accept(tkn);
    }

    // ─── registerToken ───────────────────────────────────────────────────────────

    function test_RegisterToken_HappyPath() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.PENDING));
        assertTrue(registry.vaultOf(launchToken) != address(0));
    }

    function test_RegisterToken_AdapterNotWhitelistedReverts() public {
        address fakeAdapter = makeAddr("fakeAdapter");
        vm.expectRevert(
            abi.encodeWithSelector(Registry.AdapterNotWhitelisted.selector, fakeAdapter)
        );
        registry.registerToken(
            launchToken,
            fakeAdapter,
            CREATOR_ID,
            _makeSplits1(recipient1),
            fallbackAddr,
            keccak256("id")
        );
    }

    function test_RegisterToken_FallbackNotWhitelistedReverts() public {
        address fakeFallback = makeAddr("fakeFallback");
        (address predicted,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted);
        launchpad.setLocked(launchToken, true);

        vm.expectRevert(
            abi.encodeWithSelector(Registry.FallbackNotWhitelisted.selector, fakeFallback)
        );
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            _makeSplits1(recipient1),
            fakeFallback,
            keccak256("id")
        );
    }

    function test_RegisterToken_AdapterReturnsFalseReverts() public {
        (address predicted,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted);
        launchpad.setLocked(launchToken, false); // NOT locked → adapter returns false

        vm.expectRevert(
            abi.encodeWithSelector(Registry.AdapterRejected.selector, launchToken, address(adapter))
        );
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            _makeSplits1(recipient1),
            fallbackAddr,
            keccak256("id")
        );
    }

    function test_RegisterToken_AlreadyRegisteredReverts() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        (address predicted2,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted2);
        launchpad.setLocked(launchToken, true);

        vm.expectRevert(
            abi.encodeWithSelector(Registry.TokenAlreadyRegistered.selector, launchToken)
        );
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            _makeSplits1(recipient1),
            fallbackAddr,
            keccak256("id")
        );
    }

    function test_RegisterToken_11SplitsReverts() public {
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](11);
        for (uint i = 0; i < 11; i++) {
            splits[i] = Registry.SplitInput({recipient: makeAddr(string(abi.encode(i))), bps: 0});
        }
        vm.expectRevert(); // InvalidSplits
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            splits,
            fallbackAddr,
            keccak256("id")
        );
    }

    function test_RegisterToken_BpsMismatchReverts() public {
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](2);
        splits[0] = Registry.SplitInput({recipient: recipient1, bps: 5000});
        splits[1] = Registry.SplitInput({recipient: recipient2, bps: 4999}); // sum ≠ 10000

        vm.expectRevert(
            abi.encodeWithSelector(Registry.InvalidSplits.selector, "bps must sum to 10000")
        );
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            splits,
            fallbackAddr,
            keccak256("id")
        );
    }

    // ─── accept ──────────────────────────────────────────────────────────────────

    function test_Accept_HappyPath() public {
        _registerToken(launchToken, _makeSplits1(recipient1));

        vm.prank(creatorWallet);
        registry.accept(launchToken);

        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.ACCEPTED));
    }

    function test_Accept_EmitsEvent() public {
        _registerToken(launchToken, _makeSplits1(recipient1));

        vm.expectEmit(true, true, false, false, address(registry));
        emit Registry.TokenAccepted(launchToken, CREATOR_ID);

        vm.prank(creatorWallet);
        registry.accept(launchToken);
    }

    function test_Accept_NonCreatorReverts() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.prank(alice());
        vm.expectRevert(
            abi.encodeWithSelector(Registry.NotCreatorWallet.selector, launchToken, creatorWallet, alice())
        );
        registry.accept(launchToken);
    }

    function test_Accept_FirstClaimCooldownReverts() public {
        // Attest fresh creator — no warp yet
        bytes32 newCreatorId = keccak256("newCreator");
        address newWallet = makeAddr("newWallet");
        uint48 expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _signAttest(newCreatorId, newWallet, expiry, keccak256("nc-nonce"));
        attestor.attest(PLATFORM, newCreatorId, newWallet, expiry, keccak256("nc-nonce"), sig);

        address freshToken = makeAddr("freshToken");
        (address predicted,) = factory.predictVaultAddress(address(this), freshToken);
        launchpad.setFeeRecipient(freshToken, predicted);
        launchpad.setLocked(freshToken, true);

        registry.registerToken(
            freshToken,
            address(adapter),
            newCreatorId,
            _makeSplits1(newWallet),
            fallbackAddr,
            keccak256("fid")
        );

        vm.prank(newWallet);
        vm.expectRevert(); // FirstClaimCooldownActive
        registry.accept(freshToken);
    }

    // ─── refuse ──────────────────────────────────────────────────────────────────

    function test_Refuse_HappyPath() public {
        _registerToken(launchToken, _makeSplits1(recipient1));

        vm.prank(creatorWallet);
        registry.refuse(launchToken);

        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.REFUSED));
    }

    function test_Refuse_NonCreatorReverts() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.prank(alice());
        vm.expectRevert();
        registry.refuse(launchToken);
    }

    // ─── expire ──────────────────────────────────────────────────────────────────

    function test_Expire_HappyPathAfterDeadline() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        (,, , uint48 deadline,,) = registry.getRecord(launchToken);
        vm.warp(deadline + 1);
        registry.expire(launchToken);
        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.EXPIRED));
    }

    function test_Expire_BeforeDeadlineReverts() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.expectRevert(); // DeadlineNotPassed
        registry.expire(launchToken);
    }

    function test_Expire_AnyoneCanCall() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        (,, , uint48 deadline,,) = registry.getRecord(launchToken);
        vm.warp(deadline + 1);

        vm.prank(alice());
        registry.expire(launchToken);
        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.EXPIRED));
    }

    // ─── ACCEPTED→REFUSED and lockout ────────────────────────────────────────────

    function test_AcceptedToRefused_Works() public {
        _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(creatorWallet);
        registry.refuse(launchToken);
        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.REFUSED));
    }

    function test_RefusedToAccepted_LockedOutReverts() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.prank(creatorWallet);
        registry.refuse(launchToken);

        // Immediately try to accept — 30-day lockout
        vm.prank(creatorWallet);
        vm.expectRevert(); // RefusedToAcceptedLockoutActive
        registry.accept(launchToken);
    }

    function test_RefusedToAccepted_AfterLockoutSucceeds() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.prank(creatorWallet);
        registry.refuse(launchToken);

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(creatorWallet);
        registry.accept(launchToken);
        assertEq(uint(registry.getTokenState(launchToken)), uint(Registry.TokenState.ACCEPTED));
    }

    // ─── Split recipient state transitions ───────────────────────────────────────

    function test_AcceptSplit_HappyPath() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));

        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        (,, Registry.TokenState state,) = registry.getSplit(launchToken, 0);
        assertEq(uint(state), uint(Registry.TokenState.ACCEPTED));
    }

    function test_AcceptSplit_NonRecipientReverts() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));
        vm.prank(alice());
        vm.expectRevert();
        registry.acceptSplit(launchToken, 0);
    }

    function test_RefuseSplit_HappyPath() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));
        vm.prank(recipient1);
        registry.refuseSplit(launchToken, 0);

        (,, Registry.TokenState state,) = registry.getSplit(launchToken, 0);
        assertEq(uint(state), uint(Registry.TokenState.REFUSED));
    }

    // ─── Splits change ───────────────────────────────────────────────────────────

    function test_ProposeSplitsChange_OnlyRecipientCanPropose() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));

        Registry.SplitInput[] memory newSplits = new Registry.SplitInput[](1);
        newSplits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        vm.prank(alice());
        vm.expectRevert(
            abi.encodeWithSelector(Registry.NotRecipient.selector, launchToken, alice())
        );
        registry.proposeSplitsChange(launchToken, newSplits);
    }

    function test_SplitsChange_FullSignaturePathApplies() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));

        Registry.SplitInput[] memory newSplits = new Registry.SplitInput[](1);
        newSplits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        vm.prank(recipient1);
        registry.proposeSplitsChange(launchToken, newSplits);

        _signSplits(recipient1);

        _signSplits(recipient2);

        // Change applied — now 1 recipient
        assertEq(registry.splitCountOf(launchToken), 1);
        (address r,,,) = registry.getSplit(launchToken, 0);
        assertEq(r, recipient1);
    }

    function test_SplitsChange_PartialSignatureDoesNotApply() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));

        Registry.SplitInput[] memory newSplits = new Registry.SplitInput[](1);
        newSplits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        vm.prank(recipient1);
        registry.proposeSplitsChange(launchToken, newSplits);

        _signSplits(recipient1);

        // Only 1 of 2 signed — still 2 recipients
        assertEq(registry.splitCountOf(launchToken), 2);
    }

    function test_SplitsChange_DuplicateSignReverts() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));

        Registry.SplitInput[] memory newSplits = new Registry.SplitInput[](1);
        newSplits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        vm.prank(recipient1);
        registry.proposeSplitsChange(launchToken, newSplits);

        _signSplits(recipient1);

        bytes32 pid = registry.splitChangeIdOf(launchToken);
        vm.prank(recipient1);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.SplitChangeAlreadySigned.selector, launchToken, recipient1)
        );
        registry.signSplitsChange(launchToken, pid);
    }

    // ─── setRedirect ────────────────────────────────────────────────────────────

    function test_SetRedirect_UpdatesRedirectTo() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));
        address newDest = makeAddr("newDest");

        vm.prank(recipient1);
        registry.setRedirect(launchToken, 0, newDest);

        (,,, address redirectTo) = registry.getSplit(launchToken, 0);
        assertEq(redirectTo, newDest);
    }

    function test_SetRedirect_OnlyThatRecipient() public {
        _registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2));
        vm.prank(alice());
        vm.expectRevert();
        registry.setRedirect(launchToken, 0, alice());
    }

    // ─── distributeIncoming ─────────────────────────────────────────────────────

    function test_DistributeIncoming_PendingDoesNothing() public {
        address vault = _registerToken(launchToken, _makeSplits1(recipient1));
        usdc.mint(vault, 100e6);
        FeeVault(payable(vault)).notifyReceived();

        registry.distributeIncoming(launchToken);

        // In PENDING state, no credits
        assertEq(FeeVault(payable(vault)).claimable(recipient1), 0);
    }

    function test_DistributeIncoming_AcceptedCreditsRecipients() public {
        // Register, accept token, accept split
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));

        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        // Send USDC and distribute
        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        // 10% protocol fee → recipient gets 90e6
        uint256 claimable = FeeVault(payable(vault)).claimable(recipient1);
        assertEq(claimable, 90e6);
    }

    function test_DistributeIncoming_RefusedSendsFallback() public {
        address vault = _registerToken(launchToken, _makeSplits1(recipient1));

        vm.prank(creatorWallet);
        registry.refuse(launchToken);

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        assertEq(usdc.balanceOf(fallbackAddr), 100e6);
    }

    function test_DistributeIncoming_ExpiredSplits5050() public {
        address vault = _registerToken(launchToken, _makeSplits1(recipient1));
        (,, , uint48 deadline,,) = registry.getRecord(launchToken);
        vm.warp(deadline + 1);
        registry.expire(launchToken);

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        uint256 treasuryBal = usdc.balanceOf(treasury);
        uint256 buybackBal  = usdc.balanceOf(buyback);
        // 50 each (treasury gets odd dust)
        assertEq(buybackBal, 50e6);
        assertEq(treasuryBal, 50e6);
    }

    // ─── Protocol fee ────────────────────────────────────────────────────────────

    function test_ProtocolFee_10PercentTaken() public {
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        // 10% fee → 10e6 fee → 5e6 treasury + 5e6 buyback
        // net → recipient 90e6
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.balanceOf(buyback), 5e6);
        assertEq(FeeVault(payable(vault)).claimable(recipient1), 90e6);
    }

    function test_ProtocolFee_SetAboveCapReverts() public {
        vm.prank(timelockAddr);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.ProtocolFeeExceedsCap.selector, 1501, 1500)
        );
        registry.setProtocolFee(1501);
    }

    function test_ProtocolFee_SetAtCapSucceeds() public {
        vm.prank(timelockAddr);
        registry.setProtocolFee(1500);
        assertEq(registry.protocolFeeBps(), 1500);
    }

    function test_ProtocolFee_OnlyTimelockCanSet() public {
        vm.prank(alice());
        vm.expectRevert(Registry.NotFromTimelock.selector);
        registry.setProtocolFee(500);
    }

    // ─── Pause ───────────────────────────────────────────────────────────────────

    function test_Pause_BlocksRegisterToken() public {
        vm.prank(pauser);
        registry.pause();

        (address predicted,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted);
        launchpad.setLocked(launchToken, true);

        vm.expectRevert(); // EnforcedPause
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            _makeSplits1(recipient1),
            fallbackAddr,
            keccak256("id")
        );
    }

    function test_Pause_BlocksAccept() public {
        _registerToken(launchToken, _makeSplits1(recipient1));
        vm.prank(pauser);
        registry.pause();

        vm.prank(creatorWallet);
        vm.expectRevert();
        registry.accept(launchToken);
    }

    function test_PauseClaims_BlocksExecuteClaim() public {
        // Setup: full happy path
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);
        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        // Pause claims
        vm.prank(pauser);
        registry.pauseClaims();

        // Attempting executeClaim should revert (ClaimsPausedTooLong — it's under 72h)
        bytes32 PAYOUT_ROLE = keccak256("PAYOUT_ROUTER_ROLE");
        vm.prank(admin);
        registry.grantRole(PAYOUT_ROLE, alice());

        vm.prank(alice());
        vm.expectRevert(Registry.ClaimsPausedTooLong.selector);
        registry.executeClaim(launchToken, 0, recipient1, 90e6, recipient1);
    }

    function test_PauseClaims_AutoLiftsAfter72h() public {
        // Setup
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);
        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        // Pause claims
        vm.prank(pauser);
        registry.pauseClaims();

        // Warp 72h + 1s
        vm.warp(block.timestamp + 72 hours + 1);

        // executeClaim should now succeed (auto-lift of pause)
        bytes32 PAYOUT_ROLE = keccak256("PAYOUT_ROUTER_ROLE");
        vm.prank(admin);
        registry.grantRole(PAYOUT_ROLE, alice());

        vm.prank(alice());
        // Should succeed — no revert
        registry.executeClaim(launchToken, 0, recipient1, 90e6, recipient1);
        assertEq(usdc.balanceOf(recipient1), 90e6);
    }

    // ─── 10 recipients edge case ──────────────────────────────────────────────────

    function test_TenRecipientsEdgeCase() public {
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](10);
        for (uint8 i = 0; i < 10; i++) {
            splits[i] = Registry.SplitInput({
                recipient: makeAddr(string(abi.encode(uint256(i) + 100))),
                bps: 1000
            });
        }
        address ten = makeAddr("tenToken");
        (address predicted,) = factory.predictVaultAddress(address(this), ten);
        launchpad.setFeeRecipient(ten, predicted);
        launchpad.setLocked(ten, true);
        registry.registerToken(ten, address(adapter), CREATOR_ID, splits, fallbackAddr, keccak256("lid"));
        assertEq(registry.splitCountOf(ten), 10);
    }

    // ─── 1 recipient edge case ────────────────────────────────────────────────────

    function test_OneRecipientBps10000() public {
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        usdc.mint(vault, 1000e6);
        registry.distributeIncoming(launchToken);

        // 10% fee → 900 net
        assertEq(FeeVault(payable(vault)).claimable(recipient1), 900e6);
    }

    // ─── ACCEPTED→REFUSED claimable preserved ────────────────────────────────────

    function test_AcceptedToRefused_ClaimablePreserved() public {
        address vault = _registerAndAccept(launchToken, _makeSplits1(recipient1));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        uint256 beforeClaimable = FeeVault(payable(vault)).claimable(recipient1);
        assertEq(beforeClaimable, 90e6);

        // Refuse
        vm.prank(creatorWallet);
        registry.refuse(launchToken);

        // Claimable unchanged
        assertEq(FeeVault(payable(vault)).claimable(recipient1), 90e6);
    }

    // ─── setAdapterWhitelist / setFallbackWhitelist via timelock ─────────────────

    function test_SetAdapterWhitelist_OnlyTimelock() public {
        vm.prank(alice());
        vm.expectRevert(Registry.NotFromTimelock.selector);
        registry.setAdapterWhitelist(address(adapter), false);
    }

    function test_SetFallbackWhitelist_OnlyTimelock() public {
        vm.prank(alice());
        vm.expectRevert(Registry.NotFromTimelock.selector);
        registry.setFallbackWhitelist(fallbackAddr, false);
    }

    // ─── Fuzz: splits bps sum ────────────────────────────────────────────────────

    function testFuzz_SplitsBpsSum_MustBe10000(uint16 bps1, uint16 bps2) public {
        uint256 total = uint256(bps1) + uint256(bps2);
        vm.assume(total != 10_000);

        Registry.SplitInput[] memory splits = new Registry.SplitInput[](2);
        splits[0] = Registry.SplitInput({recipient: recipient1, bps: bps1});
        splits[1] = Registry.SplitInput({recipient: recipient2, bps: bps2});

        (address predicted,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted);
        launchpad.setLocked(launchToken, true);

        vm.expectRevert(
            abi.encodeWithSelector(Registry.InvalidSplits.selector, "bps must sum to 10000")
        );
        registry.registerToken(
            launchToken,
            address(adapter),
            CREATOR_ID,
            splits,
            fallbackAddr,
            keccak256("fid")
        );
    }

    // ─── Fuzz: protocol fee never exceeds cap ─────────────────────────────────────

    function testFuzz_ProtocolFeeNeverExceedsCap(uint256 amount) public view {
        amount = bound(amount, 1, 1e15);
        uint256 maxFee = amount * 1500 / 10_000;
        uint256 fee    = amount * registry.protocolFeeBps() / 10_000;
        assertTrue(fee <= maxFee, "fee exceeds 1500 bps cap");
    }

    // ─── Shares held for PENDING split recipients ────────────────────────────────

    /// @dev r1 ACCEPTED, r2 PENDING, 100 USDC distributed once.
    function _setupHeldShare() internal returns (FeeVault vault) {
        vault = FeeVault(payable(_registerAndAccept(launchToken, _makeSplits2(recipient1, recipient2))));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);
        usdc.mint(address(vault), 100e6);
        registry.distributeIncoming(launchToken);
    }

    function test_PendingShare_NotRedistributedByRepeatedCalls() public {
        FeeVault vault = _setupHeldShare();
        for (uint256 i; i < 20; ++i) registry.distributeIncoming(launchToken);

        assertEq(vault.claimable(recipient1), 45e6);
        assertEq(registry.reservedOf(launchToken, 1), 50e6);
        assertEq(usdc.balanceOf(address(vault)), 95e6);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), 5e6);
    }

    function test_PendingShare_CreditedOnAcceptSplit() public {
        FeeVault vault = _setupHeldShare();
        vm.prank(recipient2);
        registry.acceptSplit(launchToken, 1);

        assertEq(registry.reservedOf(launchToken, 1), 0);
        assertEq(vault.claimable(recipient1), 45e6);
        assertEq(vault.claimable(recipient2), 45e6);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), 10e6);
    }

    function test_PendingShare_ToFallbackOnRefuseSplit() public {
        FeeVault vault = _setupHeldShare();
        vm.prank(recipient2);
        registry.refuseSplit(launchToken, 1);

        assertEq(registry.reservedOf(launchToken, 1), 0);
        assertEq(usdc.balanceOf(fallbackAddr), 50e6);
        assertEq(vault.claimable(recipient1), 45e6);
    }

    function test_PendingShare_SplitOnExpireSplitRecipient() public {
        _setupHeldShare();
        vm.warp(block.timestamp + 14 days + 1);
        registry.expireSplitRecipient(launchToken, 1);

        assertEq(registry.reservedOf(launchToken, 1), 0);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), 55e6);
    }

    function test_PendingShare_ToFallbackOnTokenRefuse() public {
        FeeVault vault = _setupHeldShare();
        vm.prank(creatorWallet);
        registry.refuse(launchToken);
        registry.distributeIncoming(launchToken);

        assertEq(registry.reservedOf(launchToken, 1), 0);
        assertEq(usdc.balanceOf(fallbackAddr), 50e6);
        assertEq(vault.claimable(recipient1), 45e6); // accrued claims survive refusal
    }

    function test_PendingShare_NewFeesStillFlowToAccepted() public {
        FeeVault vault = _setupHeldShare();
        usdc.mint(address(vault), 100e6);
        registry.distributeIncoming(launchToken);

        assertEq(vault.claimable(recipient1), 90e6);
        assertEq(registry.reservedOf(launchToken, 1), 100e6);
    }

    function test_Accept_CountsFeesReceivedAfterRegistration() public {
        FeeVault vault = FeeVault(payable(_registerToken(launchToken, _makeSplits2(recipient1, recipient2))));
        usdc.mint(address(vault), 1_000e6); // arrives after registerToken's snapshot

        vm.prank(creatorWallet);
        registry.accept(launchToken);

        assertEq(registry.reservedOf(launchToken, 0), 500e6);
        assertEq(registry.reservedOf(launchToken, 1), 500e6);
    }

    function test_AcceptSplit_CountsFeesReceivedSinceLastSnapshot() public {
        FeeVault vault = FeeVault(payable(_registerAndAccept(launchToken, _makeSplits1(recipient1))));
        usdc.mint(address(vault), 100e6);

        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        assertEq(vault.claimable(recipient1), 90e6);
    }

    function test_DepositCap_DistributesOnlyUpToCap() public {
        FeeVault vault = FeeVault(payable(_registerAndAccept(launchToken, _makeSplits1(recipient1))));
        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        uint256 cap = vault.depositCap();
        usdc.mint(address(vault), cap + 10e6);
        registry.distributeIncoming(launchToken); // must not revert
        registry.distributeIncoming(launchToken);

        assertEq(vault.claimable(recipient1), cap * 9 / 10);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), cap / 10);
        assertEq(usdc.balanceOf(address(vault)), cap * 9 / 10 + 10e6); // claims + excess
    }

    /// @dev Sign the pending splits change as `who` (reads the id before the prank).
    function _signSplits(address who) internal {
        bytes32 pid = registry.splitChangeIdOf(launchToken);
        vm.prank(who);
        registry.signSplitsChange(launchToken, pid);
    }

    // ─── Helper ─────────────────────────────────────────────────────────────────
    function alice() internal pure returns (address) {
        return address(uint160(uint256(keccak256("alice"))));
    }
}
