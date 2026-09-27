// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Registry}             from "../Registry.sol";
import {FeeVaultFactory}      from "../FeeVaultFactory.sol";
import {FeeVault}             from "../FeeVault.sol";
import {IdentityAttestor}     from "../IdentityAttestor.sol";
import {PayoutRouter}         from "../PayoutRouter.sol";
import {MockLaunchpadAdapter} from "../test-helpers/MockLaunchpadAdapter.sol";
import {MockERC20}            from "../test-helpers/MockERC20.sol";
import {MockLaunchpad}        from "../test-helpers/MockLaunchpad.sol";

/// @notice Regression tests for docs/security-review.md: each scenario is the finding's
///         proof of concept (docs/security-poc/NodPoC.t.sol.txt), asserting the fix.
contract SecurityRegressionTest is Test {
    MockERC20 usdc;
    FeeVaultFactory factory;
    IdentityAttestor attestor;
    Registry registry;
    PayoutRouter router;
    MockLaunchpad launchpad;
    MockLaunchpadAdapter adapter;

    address admin = makeAddr("admin");
    address timelockAddr = makeAddr("timelock");
    address pauser = makeAddr("pauser");
    address revoker = makeAddr("revoker");
    address treasury = makeAddr("treasury");
    address buyback = makeAddr("buyback");
    address fallbackAddr = makeAddr("fallback");
    address attesterAddr; uint256 attesterKey;
    address creatorWallet = makeAddr("creatorWallet");
    address A = makeAddr("A");
    address B = makeAddr("B");
    address griefer = makeAddr("griefer");

    bytes32 PLATFORM = keccak256("nod");
    bytes32 CREATOR_ID = keccak256("creator1");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");

    function setUp() public {
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = new FeeVaultFactory(admin, address(usdc), 0);
        attestor = new IdentityAttestor(admin, attesterAddr, pauser);
        launchpad = new MockLaunchpad();
        adapter = new MockLaunchpadAdapter(address(launchpad));
        registry = new Registry(address(usdc), address(factory), address(attestor), treasury, buyback,
            timelockAddr, admin, pauser, 1000, fallbackAddr);
        router = new PayoutRouter(address(registry), address(attestor), address(usdc), admin);
        vm.prank(admin); factory.setRegistry(address(registry));
        vm.startPrank(admin);
        registry.grantRole(keccak256("PAYOUT_ROUTER_ROLE"), address(router));
        attestor.grantRole(attestor.REVOKER_ROLE(), revoker);
        vm.stopPrank();
        vm.prank(timelockAddr); registry.setAdapterWhitelist(address(adapter), true);
        _attest(CREATOR_ID, creatorWallet, "n1");
        vm.warp(block.timestamp + 7 days + 1);
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _attest(bytes32 id, address wallet, bytes32 nonce) internal {
        uint48 expiry = uint48(block.timestamp + 30 days);
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = attestor.eip712Domain();
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying));
        bytes32 sh = keccak256(abi.encode(attestor.ATTESTATION_TYPEHASH(), PLATFORM, id, wallet, expiry, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, keccak256(abi.encodePacked("\x19\x01", domain, sh)));
        attestor.attest(PLATFORM, id, wallet, expiry, nonce, abi.encodePacked(r, s, v));
    }

    function _splits2(address r1, uint16 b1, address r2, uint16 b2) internal pure returns (Registry.SplitInput[] memory s) {
        s = new Registry.SplitInput[](2);
        s[0] = Registry.SplitInput(r1, b1); s[1] = Registry.SplitInput(r2, b2);
    }

    function _splits1(address r1) internal pure returns (Registry.SplitInput[] memory s) {
        s = new Registry.SplitInput[](1);
        s[0] = Registry.SplitInput(r1, 10_000);
    }

    function _register(address tkn, bytes32 creatorId, Registry.SplitInput[] memory s) internal returns (address vault) {
        (address predicted,) = factory.predictVaultAddress(address(this), tkn);
        launchpad.setFeeRecipient(tkn, predicted);
        launchpad.setLocked(tkn, true);
        registry.registerToken(tkn, address(adapter), creatorId, s, fallbackAddr, bytes32("lp"));
        vault = registry.vaultOf(tkn);
    }

    function _sign(address who) internal {
        bytes32 id = registry.splitChangeIdOf(tokenA);
        vm.prank(who); registry.signSplitsChange(tokenA, id);
    }

    /// Both recipients accepted, each with 450 USDC credited.
    function _setupTwoAccepted() internal returns (FeeVault vault) {
        vault = FeeVault(payable(_register(tokenA, CREATOR_ID, _splits2(A, 5000, B, 5000))));
        vm.prank(creatorWallet); registry.accept(tokenA);
        vm.prank(A); registry.acceptSplit(tokenA, 0);
        vm.prank(B); registry.acceptSplit(tokenA, 1);
        usdc.mint(address(vault), 1000e6);
        registry.distributeIncoming(tokenA);
        assertEq(vault.claimable(A), 450e6);
        assertEq(vault.claimable(B), 450e6);
    }

    // ─── Finding 1: signatures commit to a proposal ─────────────────────────────

    function test_Fix1_SignatureCannotBeReusedForASwappedProposal() public {
        _setupTwoAccepted();
        vm.prank(A); registry.proposeSplitsChange(tokenA, _splits2(A, 6000, B, 4000));
        bytes32 agreed = registry.splitChangeIdOf(tokenA);
        _sign(A);
        // A swaps the proposal before B's signature lands.
        vm.prank(A); registry.proposeSplitsChange(tokenA, _splits1(A));
        _sign(A);
        // B's signature is for the agreed 60/40 proposal: rejected, nothing applied.
        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(
            Registry.StaleSplitsProposal.selector, tokenA, registry.splitChangeIdOf(tokenA), agreed
        ));
        registry.signSplitsChange(tokenA, agreed);
        assertEq(registry.splitCountOf(tokenA), 2);
    }

    // ─── Finding 4: credit belongs to the address ───────────────────────────────

    function test_Fix4_RemovedRecipientStillClaimsTheirCredit() public {
        FeeVault vault = _setupTwoAccepted();
        vm.prank(A); registry.proposeSplitsChange(tokenA, _splits1(A));
        _sign(A);
        _sign(B); // B agrees to leave
        assertEq(registry.splitCountOf(tokenA), 1);

        vm.prank(B); uint256 got = router.claim(tokenA, 0);
        assertEq(got, 450e6);
        assertEq(usdc.balanceOf(B), 450e6);
        assertEq(vault.claimable(B), 0);
    }

    // ─── Finding 2: a split change after day 14 gets a fresh decision window ────

    function test_Fix2_SplitChangeAfterDeadlineCannotBeGriefed() public {
        _setupTwoAccepted();
        vm.warp(block.timestamp + 15 days);
        vm.prank(A); registry.proposeSplitsChange(tokenA, _splits2(A, 5000, B, 5000));
        _sign(A);
        _sign(B); // applied: both PENDING, new 14-day window
        vm.startPrank(griefer);
        vm.expectRevert();
        registry.expireSplitRecipient(tokenA, 0);
        vm.stopPrank();
        vm.prank(A); registry.acceptSplit(tokenA, 0);
        vm.prank(A); uint256 got = router.claim(tokenA, 0);
        assertEq(got, 450e6);
    }

    // ─── Finding 5: transitions settle funds under the previous state ───────────

    function test_Fix5_AcceptAfterExpirySettlesTheExpiredShare() public {
        FeeVault vault = FeeVault(payable(_register(tokenA, CREATOR_ID, _splits1(A))));
        usdc.mint(address(vault), 1000e6);
        vm.warp(block.timestamp + 15 days);
        registry.expire(tokenA);
        vm.prank(creatorWallet); registry.accept(tokenA);
        vm.prank(A); registry.acceptSplit(tokenA, 0);
        assertEq(vault.claimable(A), 0);
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), 1000e6);
    }

    function test_Fix5_AcceptAfterRefusalSettlesTheFallbackShare() public {
        FeeVault vault = FeeVault(payable(_register(tokenA, CREATOR_ID, _splits1(A))));
        vm.prank(creatorWallet); registry.refuse(tokenA);
        usdc.mint(address(vault), 1000e6);
        vm.warp(block.timestamp + 31 days);
        vm.prank(creatorWallet); registry.accept(tokenA);
        vm.prank(A); registry.acceptSplit(tokenA, 0);
        assertEq(vault.claimable(A), 0);
        assertEq(usdc.balanceOf(fallbackAddr), 1000e6);
    }

    // ─── Finding 12: refuse respects the first-claim cooldown ───────────────────

    function test_Fix12_RefuseRespectsTheFirstClaimCooldown() public {
        bytes32 freshId = keccak256("fresh");
        address freshWallet = makeAddr("freshWallet");
        _attest(freshId, freshWallet, "n2");
        _register(tokenA, freshId, _splits1(A));
        vm.prank(freshWallet);
        vm.expectRevert();
        registry.refuse(tokenA);
        assertEq(uint256(registry.getTokenState(tokenA)), uint256(Registry.TokenState.PENDING));
    }

    // ─── Finding 6: splits cannot expire before the token is accepted ───────────

    function test_Fix6_SplitsCannotExpireBeforeTheTokenIsAccepted() public {
        bytes32 lateId = keccak256("late");
        address lateWallet = makeAddr("lateWallet");
        _register(tokenA, lateId, _splits1(A));
        vm.warp(block.timestamp + 10 days);
        _attest(lateId, lateWallet, "n3");
        vm.warp(block.timestamp + 4 days + 1);
        vm.startPrank(griefer);
        registry.expire(tokenA); // the token-level deadline is by design
        vm.expectRevert(abi.encodeWithSelector(
            Registry.InvalidState.selector, tokenA, Registry.TokenState.EXPIRED, Registry.TokenState.ACCEPTED
        ));
        registry.expireSplitRecipient(tokenA, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        vm.prank(lateWallet); registry.accept(tokenA);
        vm.prank(A); registry.acceptSplit(tokenA, 0); // fresh window after acceptance
    }

    // ─── Finding 11: nothing expires while paused or just after ─────────────────

    function test_Fix11_PauseDoesNotForceExpiry() public {
        _register(tokenA, CREATOR_ID, _splits1(A));
        vm.warp(block.timestamp + 13 days);
        vm.prank(pauser); registry.pause();
        vm.warp(block.timestamp + 2 days);
        vm.prank(griefer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.expire(tokenA);

        vm.prank(pauser); registry.unpause();
        vm.prank(griefer);
        vm.expectRevert();
        registry.expire(tokenA); // grace period after the pause
        vm.prank(creatorWallet); registry.accept(tokenA);
        assertEq(uint256(registry.getTokenState(tokenA)), uint256(Registry.TokenState.ACCEPTED));
    }

    // ─── Finding 3: claims pause cannot be chained ──────────────────────────────

    function test_Fix3_ClaimsPauseCannotBeChained() public {
        _setupTwoAccepted();
        vm.prank(pauser); registry.pauseClaims();
        skip(71 hours);
        vm.prank(pauser);
        vm.expectRevert(Registry.ClaimsAlreadyPaused.selector);
        registry.pauseClaims();

        skip(2 hours); // past the 72h cap: the pause has lapsed
        vm.prank(A); router.claim(tokenA, 0);
        vm.prank(pauser);
        vm.expectRevert();
        registry.pauseClaims(); // cooldown after the previous pause
        skip(72 hours);
        vm.prank(pauser); registry.pauseClaims();
    }

    // ─── Finding 8: predictions survive other registrations ─────────────────────

    function test_Fix8_PredictedVaultsDoNotDependOnRegistrationOrder() public {
        (address predA,) = factory.predictVaultAddress(address(this), tokenA);
        (address predB,) = factory.predictVaultAddress(address(this), tokenB);
        launchpad.setFeeRecipient(tokenA, predA); launchpad.setLocked(tokenA, true);
        launchpad.setFeeRecipient(tokenB, predB); launchpad.setLocked(tokenB, true);
        usdc.mint(predB, 777e6);
        registry.registerToken(tokenA, address(adapter), CREATOR_ID, _splits1(A), fallbackAddr, bytes32("lp"));
        registry.registerToken(tokenB, address(adapter), CREATOR_ID, _splits1(A), fallbackAddr, bytes32("lp"));
        assertEq(registry.vaultOf(tokenB), predB);
        assertEq(FeeVault(payable(predB)).totalReceived(), 777e6);
    }

    function test_Fix15_DefaultCapChangeDoesNotMovePredictions() public {
        (address before,) = factory.predictVaultAddress(address(this), tokenA);
        vm.prank(timelockAddr); registry.setDefaultDepositCap(5_000e6);
        (address afterChange,) = factory.predictVaultAddress(address(this), tokenA);
        assertEq(afterChange, before);
        FeeVault vault = FeeVault(payable(_register(tokenA, CREATOR_ID, _splits1(A))));
        assertEq(vault.depositCap(), 5_000e6);
    }

    // ─── Minor: duplicate recipients are rejected ───────────────────────────────

    function test_FixMinor_DuplicateRecipientsRejected() public {
        (address predicted,) = factory.predictVaultAddress(address(this), tokenA);
        launchpad.setFeeRecipient(tokenA, predicted); launchpad.setLocked(tokenA, true);
        vm.expectRevert(abi.encodeWithSelector(Registry.DuplicateRecipient.selector, A));
        registry.registerToken(tokenA, address(adapter), CREATOR_ID, _splits2(A, 5000, A, 5000), fallbackAddr, bytes32("lp"));
    }

    // ─── Minor: one bad batch entry does not revert the batch ───────────────────

    function test_FixMinor_BatchClaimIsolatesFailures() public {
        _setupTwoAccepted();
        address[] memory toks = new address[](2);
        uint8[] memory idx = new uint8[](2);
        toks[0] = tokenA; idx[0] = 0;
        toks[1] = makeAddr("unregistered"); idx[1] = 0;
        vm.prank(A);
        (uint256 total, bool[] memory skipped) = router.batchClaim(toks, idx);
        assertEq(total, 450e6);
        assertFalse(skipped[0]);
        assertTrue(skipped[1]);
    }

    // ─── Finding 14: revocation is the multisig's, and reversible ───────────────

    function test_Fix14_AttesterKeyCannotRevoke() public {
        bytes32 role = attestor.REVOKER_ROLE();
        vm.prank(attesterAddr);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attesterAddr, role
        ));
        attestor.revoke(CREATOR_ID);
    }

    function test_Fix14_RevocationCanBeLiftedByTheTimelockAdmin() public {
        vm.prank(revoker); attestor.revoke(CREATOR_ID);
        assertEq(attestor.walletOf(CREATOR_ID), address(0));
        vm.prank(admin); attestor.unrevoke(CREATOR_ID);
        _attest(CREATOR_ID, creatorWallet, "n4");
        assertEq(attestor.walletOf(CREATOR_ID), creatorWallet);
    }
}
