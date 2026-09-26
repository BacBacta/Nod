// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Registry} from "../Registry.sol";
import {FeeVault} from "../FeeVault.sol";
import {FeeVaultFactory} from "../FeeVaultFactory.sol";
import {IdentityAttestor} from "../IdentityAttestor.sol";
import {BullcheeseAdapter} from "../BullcheeseAdapter.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockMintPlus, MockLocker, MockV3Pool, MockSwapRouter02} from "../test-helpers/MockBullcheese.sol";

/// @notice Pull-model integration: the vault owns the token's LP locker, collects its
///         fees, converts token-denominated fees to USDC under a TWAP bound.
contract BullcheeseIntegrationTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal meme;
    MockMintPlus internal mintPlus;
    MockLocker internal locker;
    MockV3Pool internal pool;
    MockSwapRouter02 internal router;
    FeeVaultFactory internal factory;
    IdentityAttestor internal attestor;
    Registry internal registry;
    BullcheeseAdapter internal adapter;

    address internal admin = makeAddr("admin");
    address internal timelock = makeAddr("timelock");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal buyback = makeAddr("buyback");
    address internal fallbackAddr = makeAddr("fallback");
    address internal keeper = makeAddr("keeper");
    address internal creator;
    uint256 internal attesterKey;

    bytes32 internal constant PLATFORM = keccak256("x");
    bytes32 internal creatorId;

    function setUp() public {
        address attesterAddr;
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        creator = makeAddr("creator");

        usdc = new MockERC20("USDC", "USDC", 6);
        meme = new MockERC20("Meme", "MEME", 18);
        mintPlus = new MockMintPlus();
        pool = new MockV3Pool(address(usdc), address(meme));
        locker = new MockLocker(creator, usdc, meme);
        mintPlus.set(address(meme), address(pool), address(locker));
        router = new MockSwapRouter02();

        factory = new FeeVaultFactory(admin, address(usdc), 0);
        attestor = new IdentityAttestor(admin, attesterAddr, pauser);
        registry = new Registry(
            address(usdc), address(factory), address(attestor), treasury, buyback,
            timelock, admin, pauser, 1000, fallbackAddr
        );
        adapter = new BullcheeseAdapter(address(mintPlus), address(usdc));

        vm.prank(admin);
        factory.setRegistry(address(registry));
        vm.startPrank(timelock);
        registry.setAdapterWhitelist(address(adapter), true);
        registry.setSwapRouter(address(router));
        vm.stopPrank();
        bytes32 keeperRole = registry.KEEPER_ROLE();
        vm.prank(admin);
        registry.grantRole(keeperRole, keeper);

        creatorId = attestor.creatorIdOf(PLATFORM, "12345");
        _attest(creator);
        vm.warp(block.timestamp + 7 days + 1);
    }

    function _attest(address wallet) internal {
        uint48 expiry = uint48(block.timestamp + 1 days);
        bytes32 nonce = keccak256("n");
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = attestor.eip712Domain();
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying
        ));
        bytes32 structHash = keccak256(abi.encode(
            attestor.ATTESTATION_TYPEHASH(), PLATFORM, creatorId, wallet, expiry, nonce
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        attestor.attest(PLATFORM, creatorId, wallet, expiry, nonce, abi.encodePacked(r, s, v));
    }

    function _splits() internal view returns (Registry.SplitInput[] memory s) {
        s = new Registry.SplitInput[](1);
        s[0] = Registry.SplitInput({recipient: creator, bps: 10_000});
    }

    /// @dev Creator hands the locker to the predicted vault, then registers.
    function _register() internal returns (FeeVault vault) {
        (address predicted,) = factory.predictVaultAddress(creator, address(meme));
        vm.startPrank(creator);
        locker.transferOwnership(predicted);
        registry.registerToken(address(meme), address(adapter), creatorId, _splits(), fallbackAddr, bytes32("bullcheese"));
        vm.stopPrank();
        vault = FeeVault(payable(registry.vaultOf(address(meme))));
        assertEq(address(vault), predicted);
    }

    function _registerAndAccept() internal returns (FeeVault vault) {
        vault = _register();
        vm.startPrank(creator);
        registry.accept(address(meme));
        registry.acceptSplit(address(meme), 0);
        vm.stopPrank();
    }

    // ─── Registration ──────────────────────────────────────────────────────────

    function test_Register_VaultTakesOwnershipOfLocker() public {
        FeeVault vault = _register();
        assertEq(locker.owner(), address(vault));
        assertEq(locker.pendingOwner(), address(0));
        assertEq(vault.feeSource(), address(locker));
    }

    function test_Register_RevertsWithoutOwnershipTransfer() public {
        vm.prank(creator);
        vm.expectRevert(); // vault cannot accept: it is not the locker's pending owner
        registry.registerToken(address(meme), address(adapter), creatorId, _splits(), fallbackAddr, bytes32("b"));
        assertEq(locker.owner(), creator);
    }

    function test_Register_RevertsIfPoolIsNotPairedWithUsdc() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        mintPlus.set(address(meme), address(new MockV3Pool(address(other), address(meme))), address(locker));
        (address predicted,) = factory.predictVaultAddress(creator, address(meme));
        vm.startPrank(creator);
        locker.transferOwnership(predicted);
        vm.expectRevert(abi.encodeWithSelector(Registry.AdapterRejected.selector, address(meme), address(adapter)));
        registry.registerToken(address(meme), address(adapter), creatorId, _splits(), fallbackAddr, bytes32("b"));
        vm.stopPrank();
    }

    // ─── Collecting ────────────────────────────────────────────────────────────

    function test_CollectFees_UsdcIsDistributedTokenIsHeld() public {
        FeeVault vault = _registerAndAccept();
        locker.accrue(100e6, 500e18);

        registry.collectFees(address(meme)); // permissionless

        assertEq(vault.claimable(creator), 90e6);                 // 100 USDC minus 10% protocol fee
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(buyback), 10e6);
        assertEq(meme.balanceOf(address(vault)), 500e18);          // waits for swapTokenFees
    }

    function test_CollectFees_WhilePendingAccumulates() public {
        FeeVault vault = _register();
        locker.accrue(100e6, 0);
        registry.collectFees(address(meme));
        assertEq(vault.totalReceived(), 100e6);
        assertEq(vault.claimable(creator), 0);
    }

    // ─── Swapping token fees ───────────────────────────────────────────────────

    function test_SwapTokenFees_ConvertsAtTwapAndDistributes() public {
        FeeVault vault = _registerAndAccept();
        locker.accrue(0, 1_000e6); // tick 0 => 1 raw token unit = 1 raw USDC unit
        registry.collectFees(address(meme));

        vm.prank(keeper);
        registry.swapTokenFees(address(meme), 1_000e6, 990e6);

        assertEq(meme.balanceOf(address(vault)), 0);
        assertEq(vault.claimable(creator), 900e6);
    }

    function test_SwapTokenFees_RejectsMinOutBelowTwapBound() public {
        _registerAndAccept();
        locker.accrue(0, 1_000e6);
        registry.collectFees(address(meme));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Registry.MinOutBelowTwap.selector, 900e6, 970e6));
        registry.swapTokenFees(address(meme), 1_000e6, 900e6);
    }

    function test_SwapFloor_MatchesTheSwapBound() public {
        _registerAndAccept();
        (uint256 twapOut, uint256 floor) = registry.swapFloor(address(meme), 1_000e6);
        assertEq(twapOut, 1_000e6);
        assertEq(floor, 970e6);
    }

    function test_SwapTokenFees_RevertsWhenPoolPriceIsBelowMinOut() public {
        _registerAndAccept();
        locker.accrue(0, 1_000e6);
        registry.collectFees(address(meme));
        router.setRateBps(9_000); // spot 10% under TWAP (e.g. manipulated)

        vm.prank(keeper);
        vm.expectRevert(bytes("Too little received"));
        registry.swapTokenFees(address(meme), 1_000e6, 980e6);
    }

    function test_SwapTokenFees_OnlyKeeper() public {
        _registerAndAccept();
        vm.expectRevert();
        registry.swapTokenFees(address(meme), 1e6, 1e6);
    }

    function test_SwapTokenFees_RequiresRouterAndHistory() public {
        _registerAndAccept();
        locker.accrue(0, 1_000e6);
        registry.collectFees(address(meme));

        pool.setTooYoung(true);
        vm.prank(keeper);
        vm.expectRevert(bytes("OLD"));
        registry.swapTokenFees(address(meme), 1_000e6, 1_000e6);

        vm.prank(timelock);
        registry.setSwapRouter(address(0));
        vm.prank(keeper);
        vm.expectRevert(Registry.SwapRouterNotSet.selector);
        registry.swapTokenFees(address(meme), 1_000e6, 1_000e6);
    }

    function test_PrepareSwapOracle_GrowsPoolHistory() public {
        _register();
        registry.prepareSwapOracle(address(meme), 120);
        assertEq(pool.cardinalityNext(), 120);
    }

    // ─── Liquidity stays locked ────────────────────────────────────────────────

    function test_VaultCannotBeMadeToWithdrawOrReleaseTheLock() public {
        FeeVault vault = _register();
        bytes4[3] memory forbidden = [
            bytes4(keccak256("withdrawLiquidityLock()")),
            Ownable.transferOwnership.selector,
            Ownable.renounceOwnership.selector
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSelector(forbidden[i], creator));
            assertFalse(ok);
        }
        assertEq(locker.owner(), address(vault));
        assertEq(locker.withdrawCalls(), 0);

        // The former owner lost control too.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        locker.collectFees();
    }

    function test_AcceptFeeSource_OnlyRegistryAndOnce() public {
        FeeVault vault = _register();
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.acceptFeeSource(address(locker));
        vm.prank(address(registry));
        vm.expectRevert(FeeVault.FeeSourceAlreadySet.selector);
        vault.acceptFeeSource(address(locker));
    }
}
