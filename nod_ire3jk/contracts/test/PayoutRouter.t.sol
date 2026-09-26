// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PayoutRouter}      from "../PayoutRouter.sol";
import {Registry}          from "../Registry.sol";
import {FeeVaultFactory}   from "../FeeVaultFactory.sol";
import {FeeVault}          from "../FeeVault.sol";
import {IdentityAttestor}  from "../IdentityAttestor.sol";
import {MockLaunchpadAdapter} from "../test-helpers/MockLaunchpadAdapter.sol";

import {MockERC20}     from "../test-helpers/MockERC20.sol";
import {MockLaunchpad} from "../test-helpers/MockLaunchpad.sol";

contract PayoutRouterTest is Test {
    // ─── Contracts ───────────────────────────────────────────────────────────────
    MockERC20         internal usdc;
    FeeVaultFactory   internal factory;
    IdentityAttestor  internal attestor;
    Registry          internal registry;
    PayoutRouter      internal router;
    MockLaunchpad     internal launchpad;
    MockLaunchpadAdapter internal adapter;

    // ─── Keys ────────────────────────────────────────────────────────────────────
    address internal admin   = makeAddr("admin");
    address internal timelockAddr = makeAddr("timelock");
    address internal pauser  = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal buyback  = makeAddr("buyback");
    address internal fallbackAddr = makeAddr("fallback");

    address internal attesterAddr;
    uint256 internal attesterKey;

    address internal creatorWallet;
    uint256 internal creatorKey;
    address internal recipient1;

    bytes32 internal PLATFORM   = keccak256("nod");
    bytes32 internal CREATOR_ID = keccak256("creator1");

    address internal launchToken = makeAddr("launchToken");

    function setUp() public {
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        (creatorWallet, creatorKey) = makeAddrAndKey("creatorWallet");
        recipient1 = makeAddr("recipient1");

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
            1000,
            fallbackAddr
        );

        router = new PayoutRouter(
            address(registry),
            address(attestor),
            address(usdc),
            admin
        );

        // Wire
        vm.prank(admin);
        factory.setRegistry(address(registry));

        vm.startPrank(timelockAddr);
        registry.setAdapterWhitelist(address(adapter), true);
        registry.setFallbackWhitelist(fallbackAddr, true);
        vm.stopPrank();

        // Grant PAYOUT_ROUTER_ROLE to router
        bytes32 PAYOUT_ROLE = keccak256("PAYOUT_ROUTER_ROLE");
        vm.prank(admin);
        registry.grantRole(PAYOUT_ROLE, address(router));

        // Attest creator
        _attestCreator(creatorWallet, keccak256("cn1"));
        vm.warp(block.timestamp + 7 days + 1);
    }

    // ─── EIP-712 helpers ─────────────────────────────────────────────────────────

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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, d);
        return abi.encodePacked(r, s, v);
    }

    function _attestCreator(address wallet, bytes32 nonce) internal {
        uint48 expiry = uint48(block.timestamp + 30 days);
        bytes memory sig = _signAttest(CREATOR_ID, wallet, expiry, nonce);
        attestor.attest(PLATFORM, CREATOR_ID, wallet, expiry, nonce, sig);
    }

    // ─── Setup helper: register → accept token → accept split ─────────────────

    function _fullSetup() internal returns (address vault) {
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](1);
        splits[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});

        (address predicted,) = factory.predictVaultAddress(address(this), launchToken);
        launchpad.setFeeRecipient(launchToken, predicted);
        launchpad.setLocked(launchToken, true);

        registry.registerToken(launchToken, address(adapter), CREATOR_ID, splits, fallbackAddr, keccak256("lid"));

        vm.prank(creatorWallet);
        registry.accept(launchToken);

        vm.prank(recipient1);
        registry.acceptSplit(launchToken, 0);

        vault = registry.vaultOf(launchToken);
    }

    // ─── claim: happy path ───────────────────────────────────────────────────────

    function test_Claim_HappyPath() public {
        address vault = _fullSetup();

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        uint256 claimable = FeeVault(payable(vault)).claimable(recipient1);
        assertEq(claimable, 90e6);

        uint256 before = usdc.balanceOf(recipient1);
        vm.prank(recipient1);
        uint256 claimed = router.claim(launchToken, 0);

        assertEq(claimed, 90e6);
        assertEq(usdc.balanceOf(recipient1), before + 90e6);
        assertEq(FeeVault(payable(vault)).claimable(recipient1), 0);
    }

    function test_Claim_WithPayoutOverride() public {
        address vault = _fullSetup();
        address overrideAddr = makeAddr("override");

        usdc.mint(vault, 100e6);
        registry.distributeIncoming(launchToken);

        // Set override
        vm.prank(recipient1);
        router.setPayoutOverride(overrideAddr);

        vm.prank(recipient1);
        router.claim(launchToken, 0);

        assertEq(usdc.balanceOf(overrideAddr), 90e6);
        assertEq(usdc.balanceOf(recipient1), 0);
    }

    function test_Claim_ZeroClaimableReverts() public {
        _fullSetup();
        // No USDC sent → nothing to claim
        vm.prank(recipient1);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutRouter.NothingToClaim.selector, launchToken, uint8(0))
        );
        router.claim(launchToken, 0);
    }

    function test_Claim_WrongCallerReverts() public {
        _fullSetup();
        address wrong = makeAddr("wrong");
        vm.prank(wrong);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutRouter.NotRecipientWallet.selector, launchToken, uint8(0), wrong)
        );
        router.claim(launchToken, 0);
    }

    // ─── batchClaim ──────────────────────────────────────────────────────────────

    function test_BatchClaim_HappyPath() public {
        address vault = _fullSetup();

        // Deploy a second token
        address launchToken2 = makeAddr("launchToken2");
        Registry.SplitInput[] memory splits2 = new Registry.SplitInput[](1);
        splits2[0] = Registry.SplitInput({recipient: recipient1, bps: 10_000});
        (address predicted2,) = factory.predictVaultAddress(address(this), launchToken2);
        launchpad.setFeeRecipient(launchToken2, predicted2);
        launchpad.setLocked(launchToken2, true);
        registry.registerToken(launchToken2, address(adapter), CREATOR_ID, splits2, fallbackAddr, keccak256("lid2"));
        vm.prank(creatorWallet);
        registry.accept(launchToken2);
        vm.prank(recipient1);
        registry.acceptSplit(launchToken2, 0);

        address vault2 = registry.vaultOf(launchToken2);

        usdc.mint(vault, 100e6);
        usdc.mint(vault2, 100e6);
        registry.distributeIncoming(launchToken);
        registry.distributeIncoming(launchToken2);

        address[] memory tokens = new address[](2);
        tokens[0] = launchToken;
        tokens[1] = launchToken2;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0;
        idxs[1] = 0;

        uint256 before = usdc.balanceOf(recipient1);
        vm.prank(recipient1);
        (uint256 total, bool[] memory skipped) = router.batchClaim(tokens, idxs);

        assertEq(total, 180e6); // 90 + 90
        assertFalse(skipped[0]);
        assertFalse(skipped[1]);
        assertEq(usdc.balanceOf(recipient1), before + 180e6);
    }

    function test_BatchClaim_SkipsZeroClaimable() public {
        _fullSetup();

        address[] memory tokens = new address[](1);
        tokens[0] = launchToken;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;

        vm.prank(recipient1);
        (uint256 total, bool[] memory skipped) = router.batchClaim(tokens, idxs);

        assertEq(total, 0);
        assertTrue(skipped[0]);
    }

    function test_BatchClaim_TooManyEntriesReverts() public {
        address[] memory tokens = new address[](51);
        uint8[]   memory idxs  = new uint8[](51);

        vm.prank(recipient1);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutRouter.BatchTooLarge.selector, 51, 50)
        );
        router.batchClaim(tokens, idxs);
    }

    // ─── setPayoutOverride ───────────────────────────────────────────────────────

    function test_SetPayoutOverride_Works() public {
        vm.prank(recipient1);
        router.setPayoutOverride(makeAddr("dest"));
        assertEq(router.payoutOverride(recipient1), makeAddr("dest"));
    }

    function test_SetPayoutOverride_EmitsEvent() public {
        address dest = makeAddr("dest");
        vm.expectEmit(true, true, false, false, address(router));
        emit PayoutRouter.PayoutOverrideSet(recipient1, dest);
        vm.prank(recipient1);
        router.setPayoutOverride(dest);
    }
}
