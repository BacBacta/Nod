// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuybackModule} from "../BuybackModule.sol";
import {MockERC20}     from "../test-helpers/MockERC20.sol";
import {MockUniswapRouter} from "../test-helpers/MockUniswapRouter.sol";
import {MockV3Pool} from "../test-helpers/MockBullcheese.sol";

contract BuybackModuleTest is Test {
    BuybackModule      internal module;
    MockERC20          internal usdc;
    MockERC20          internal nodToken;
    MockUniswapRouter  internal router;

    address internal timelockAddr = makeAddr("timelock");
    address internal adminAddr    = makeAddr("admin");
    address internal keeperAddr   = makeAddr("keeper");
    address internal alice        = makeAddr("alice");

    uint24  internal constant POOL_FEE  = 3000;
    uint256 internal constant SLIPPAGE  = 100; // 1%
    uint256 internal constant INTERVAL  = 7 days;

    MockV3Pool internal pool;

    /// @dev Production setup: $NOD token, TWAP pool, then an explicit enable.
    function _enable() internal {
        pool = new MockV3Pool(address(usdc), address(nodToken)); // TWAP tick 0: 1 raw USDC = 1 raw NOD
        pool.setFee(POOL_FEE);
        vm.startPrank(timelockAddr);
        module.setNodToken(address(nodToken));
        module.setPool(address(pool));
        module.setDisabled(false);
        vm.stopPrank();
    }

    function setUp() public {
        usdc     = new MockERC20("Mock USDC", "mUSDC", 6);
        nodToken = new MockERC20("NOD Token", "NOD", 18);
        router   = new MockUniswapRouter(1000e18, address(nodToken));

        module = new BuybackModule(
            address(usdc),
            timelockAddr,
            address(router),
            POOL_FEE,
            SLIPPAGE,
            INTERVAL,
            adminAddr,
            keeperAddr
        );
    }

    // ─── executeBuyback — disabled reverts ───────────────────────────────────────

    function test_ExecuteBuyback_DisabledReverts() public {
        // disabled = true by default (no nodToken set)
        vm.prank(keeperAddr);
        vm.expectRevert(BuybackModule.BuybackDisabledError.selector);
        module.executeBuyback(100e6, 95e18, block.timestamp + 1 hours);
    }

    // ─── executeBuyback — nodToken not set reverts ───────────────────────────────

    function test_ExecuteBuyback_NodTokenNotSetReverts() public {
        // Enable module via timelock but don't set nodToken
        vm.prank(timelockAddr);
        module.setDisabled(false);

        vm.prank(keeperAddr);
        vm.expectRevert(BuybackModule.NodTokenNotSet.selector);
        module.executeBuyback(100e6, 95e18, block.timestamp + 1 hours);
    }

    // ─── executeBuyback — too early reverts ──────────────────────────────────────

    function test_ExecuteBuyback_TooEarlyReverts() public {
        // Set nodToken via timelock (also re-enables)
        _enable();

        // First call succeeds
        usdc.mint(address(module), 1000e6);
        nodToken.mint(address(router), 1000e18);

        uint256 minOut = 100e6 * (10_000 - SLIPPAGE) / 10_000;
        vm.prank(keeperAddr);
        module.executeBuyback(100e6, minOut, block.timestamp + 1 hours);

        // Second call — too early
        usdc.mint(address(module), 1000e6);
        vm.prank(keeperAddr);
        vm.expectRevert(); // TooEarlyForBuyback
        module.executeBuyback(100e6, minOut, block.timestamp + 2 hours);
    }

    // ─── executeBuyback — happy path ─────────────────────────────────────────────

    function test_ExecuteBuyback_HappyPath() public {
        _enable();

        uint256 amountIn = 100e6;
        usdc.mint(address(module), amountIn);
        nodToken.mint(address(router), 1000e18);

        uint256 minOut = amountIn * (10_000 - SLIPPAGE) / 10_000;

        vm.expectEmit(false, false, true, false, address(module));
        emit BuybackModule.BuybackExecuted(amountIn, 1000e18, keeperAddr, block.timestamp);

        vm.prank(keeperAddr);
        module.executeBuyback(amountIn, minOut, block.timestamp + 1 hours);

        // USDC spent, NOD burned
        address dead = 0x000000000000000000000000000000000000dEaD;
        assertEq(nodToken.balanceOf(dead), 1000e18);
    }

    function test_ExecuteBuyback_NextAllowedAtUpdated() public {
        _enable();

        usdc.mint(address(module), 100e6);
        nodToken.mint(address(router), 1000e18);

        uint256 minOut = 100e6 * (10_000 - SLIPPAGE) / 10_000;
        vm.prank(keeperAddr);
        module.executeBuyback(100e6, minOut, block.timestamp + 1 hours);

        assertEq(module.nextAllowedAt(), block.timestamp + INTERVAL);
    }

    function test_ExecuteBuyback_OnlyKeeper() public {
        _enable();

        usdc.mint(address(module), 100e6);
        vm.prank(alice);
        vm.expectRevert(); // AccessControl
        module.executeBuyback(100e6, 0, block.timestamp + 1);
    }

    function test_ExecuteBuyback_SlippageTooLowReverts() public {
        _enable();

        usdc.mint(address(module), 100e6);
        nodToken.mint(address(router), 1000e18);

        // minOut way below required
        vm.prank(keeperAddr);
        vm.expectRevert(); // SlippageExceedsMax
        module.executeBuyback(100e6, 0, block.timestamp + 1 hours);
    }

    function test_ExecuteBuyback_InsufficientBalanceReverts() public {
        _enable();

        // No USDC in module
        uint256 minOut = 100e6 * (10_000 - SLIPPAGE) / 10_000;
        vm.prank(keeperAddr);
        vm.expectRevert(); // InsufficientUsdcBalance
        module.executeBuyback(100e6, minOut, block.timestamp + 1 hours);
    }

    // ─── Timelock-gated setters ──────────────────────────────────────────────────

    function test_SetNodToken_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setNodToken(address(nodToken));
    }

    function test_SetSwapRouter_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setSwapRouter(address(router));
    }

    function test_SetPoolFee_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setPoolFee(500);
    }

    function test_SetMaxSlippage_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setMaxSlippage(200);
    }

    function test_SetScheduleInterval_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setScheduleInterval(3 days);
    }

    function test_SetDisabled_OnlyTimelock() public {
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotFromTimelock.selector);
        module.setDisabled(false);
    }

    function test_SetNodToken_ZeroAddressReverts() public {
        vm.prank(timelockAddr);
        vm.expectRevert(BuybackModule.ZeroAddress.selector);
        module.setNodToken(address(0));
    }

    function test_SetNodToken_DoesNotEnableBuyback() public {
        vm.prank(timelockAddr);
        module.setNodToken(address(nodToken));
        assertTrue(module.disabled()); // enabling is an explicit setDisabled(false)
    }

    function test_SetNodToken_KeepsExplicitDisable() public {
        _enable();
        vm.prank(timelockAddr);
        module.setDisabled(true);
        vm.prank(timelockAddr);
        module.setNodToken(address(nodToken));
        assertTrue(module.disabled());
    }

    function test_SetMaxSlippage_AboveCap5000Reverts() public {
        vm.prank(timelockAddr);
        vm.expectRevert(); // SlippageExceedsMax
        module.setMaxSlippage(5001);
    }

    // ─── receive() reverts ───────────────────────────────────────────────────────

    function test_ReceiveReverts() public {
        vm.expectRevert(BuybackModule.NativeNotAccepted.selector);
        (bool s,) = address(module).call{value: 1}("");
        (s);
    }

    // ─── accumulatedUsdc view ────────────────────────────────────────────────────

    function test_AccumulatedUsdc() public {
        usdc.mint(address(module), 500e6);
        assertEq(module.accumulatedUsdc(), 500e6);
    }
}
