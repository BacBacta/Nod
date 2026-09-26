// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeVault} from "../FeeVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract FeeVaultTest is Test {
    MockERC20 internal usdc;
    FeeVault  internal vault;

    address internal factory  = makeAddr("factory");
    address internal registry = makeAddr("registry");
    address internal token    = makeAddr("token");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");

    uint256 internal constant CAP = 1_000_000e6; // 1M USDC

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // Deploy vault from factory address
        vm.prank(factory);
        vault = new FeeVault(address(usdc), factory, token, keccak256("salt"), CAP);

        // Wire registry
        vm.prank(factory);
        vault.setRegistry(registry);
    }

    // ─── setRegistry ────────────────────────────────────────────────────────────

    function test_SetRegistry_OnlyFactory() public {
        // Deploy fresh vault without registry
        vm.prank(factory);
        FeeVault v2 = new FeeVault(address(usdc), factory, token, keccak256("salt2"), 0);

        vm.prank(alice);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        v2.setRegistry(registry);
    }

    function test_SetRegistry_OneTimeOnly() public {
        // Already set in setUp — try again
        vm.prank(factory);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.setRegistry(alice);
    }

    function test_SetRegistry_ZeroAddress() public {
        vm.prank(factory);
        FeeVault v2 = new FeeVault(address(usdc), factory, token, keccak256("salt3"), 0);
        vm.prank(factory);
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        v2.setRegistry(address(0));
    }

    // ─── notifyReceived ──────────────────────────────────────────────────────────

    function test_NotifyReceived_CreditsCorrectDelta() public {
        usdc.mint(address(vault), 100e6);
        vault.notifyReceived();
        assertEq(vault.totalReceived(), 100e6);
    }

    function test_NotifyReceived_DoubleCallIdempotent() public {
        usdc.mint(address(vault), 100e6);
        vault.notifyReceived();
        vault.notifyReceived(); // second call — no new funds
        assertEq(vault.totalReceived(), 100e6, "double call must not double-count");
    }

    function test_NotifyReceived_AccumulatesMultipleDeposits() public {
        usdc.mint(address(vault), 50e6);
        vault.notifyReceived();
        usdc.mint(address(vault), 50e6);
        vault.notifyReceived();
        assertEq(vault.totalReceived(), 100e6);
    }

    function test_NotifyReceived_AccountsForOutflows() public {
        usdc.mint(address(vault), 200e6);
        vault.notifyReceived();

        // Simulate a transferOut — registry moves funds out
        vm.prank(registry);
        vault.transferOut(alice, 50e6, keccak256("TEST"));

        // New deposit comes in
        usdc.mint(address(vault), 30e6);
        vault.notifyReceived();

        // totalReceived should be 200 + 30 = 230
        assertEq(vault.totalReceived(), 230e6);
    }

    // ─── Deposit cap ────────────────────────────────────────────────────────────

    function test_DepositCap_ExceedingCapReverts() public {
        usdc.mint(address(vault), CAP + 1);
        vm.expectRevert(
            abi.encodeWithSelector(FeeVault.DepositCapExceeded.selector, CAP, CAP + 1)
        );
        vault.notifyReceived();
    }

    function test_DepositCap_ExactlyAtCapSucceeds() public {
        usdc.mint(address(vault), CAP);
        vault.notifyReceived();
        assertEq(vault.totalReceived(), CAP);
    }

    function test_DepositCap_ZeroMeansNoCap() public {
        // Deploy a vault with cap=0
        vm.prank(factory);
        FeeVault uncapped = new FeeVault(address(usdc), factory, token, keccak256("uncapped"), 0);
        vm.prank(factory);
        uncapped.setRegistry(registry);

        uint256 huge = 1e15; // very large
        usdc.mint(address(uncapped), huge);
        uncapped.notifyReceived(); // should not revert
        assertEq(uncapped.totalReceived(), huge);
    }

    function test_DepositCap_SetByRegistry() public {
        vm.prank(registry);
        vault.setDepositCap(500e6);
        assertEq(vault.depositCap(), 500e6);
    }

    function test_DepositCap_SetByRegistry_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.setDepositCap(500e6);
    }

    // ─── credit ─────────────────────────────────────────────────────────────────

    function test_Credit_IncrementsClaimable() public {
        vm.prank(registry);
        vault.credit(alice, 100e6);
        assertEq(vault.claimable(alice), 100e6);
        assertEq(vault.totalCredited(), 100e6);
    }

    function test_Credit_MultipleCallsAccumulate() public {
        vm.prank(registry);
        vault.credit(alice, 50e6);
        vm.prank(registry);
        vault.credit(alice, 25e6);
        assertEq(vault.claimable(alice), 75e6);
    }

    function test_Credit_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.credit(alice, 100e6);
    }

    function test_Credit_ZeroAddressReverts() public {
        vm.prank(registry);
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        vault.credit(address(0), 100e6);
    }

    // ─── withdrawFor ────────────────────────────────────────────────────────────

    function test_WithdrawFor_DecrementsClaimableAndTransfers() public {
        // Seed vault and credit alice
        usdc.mint(address(vault), 100e6);
        vm.prank(registry);
        vault.credit(alice, 100e6);

        uint256 beforeBalance = usdc.balanceOf(bob);
        vm.prank(registry);
        vault.withdrawFor(alice, bob, 60e6);

        assertEq(vault.claimable(alice), 40e6);
        assertEq(vault.totalWithdrawn(), 60e6);
        assertEq(usdc.balanceOf(bob), beforeBalance + 60e6);
    }

    function test_WithdrawFor_OnlyRegistry() public {
        vm.prank(registry);
        vault.credit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.withdrawFor(alice, alice, 10e6);
    }

    function test_WithdrawFor_InsufficientClaimableReverts() public {
        vm.prank(registry);
        vault.credit(alice, 50e6);

        usdc.mint(address(vault), 100e6);

        vm.prank(registry);
        vm.expectRevert(
            abi.encodeWithSelector(FeeVault.InsufficientClaimable.selector, 50e6, 100e6)
        );
        vault.withdrawFor(alice, alice, 100e6);
    }

    // ─── transferOut ────────────────────────────────────────────────────────────

    function test_TransferOut_MovesUsdc() public {
        usdc.mint(address(vault), 200e6);
        bytes32 reason = keccak256("FALLBACK");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(registry);
        vault.transferOut(alice, 120e6, reason);

        assertEq(usdc.balanceOf(alice), before + 120e6);
        assertEq(vault.totalDirectOut(), 120e6);
    }

    function test_TransferOut_OnlyRegistry() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(alice);
        vm.expectRevert(FeeVault.NotRegistry.selector);
        vault.transferOut(alice, 50e6, keccak256("TEST"));
    }

    function test_TransferOut_InsufficientBalanceReverts() public {
        usdc.mint(address(vault), 50e6);
        vm.prank(registry);
        vm.expectRevert(
            abi.encodeWithSelector(FeeVault.InsufficientBalance.selector, 50e6, 100e6)
        );
        vault.transferOut(alice, 100e6, keccak256("TEST"));
    }

    function test_TransferOut_EmitsFundsTransferred() public {
        usdc.mint(address(vault), 100e6);
        bytes32 reason = keccak256("SPLIT_ACCEPTED");

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeeVault.FundsTransferred(alice, 100e6, reason);

        vm.prank(registry);
        vault.transferOut(alice, 100e6, reason);
    }

    // ─── receive() reverts native value ─────────────────────────────────────────

    function test_ReceiveReverts() public {
        vm.expectRevert(FeeVault.NativeNotAccepted.selector);
        (bool success,) = address(vault).call{value: 1}("");
        // The above should revert so success is false — but expectRevert handles it
        (success); // suppress unused warning
    }

    // ─── availableBalance ────────────────────────────────────────────────────────

    function test_AvailableBalance_CorrectAfterCredit() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(registry);
        vault.credit(alice, 40e6); // locks 40 for alice

        // availableBalance = balance - (totalCredited - totalWithdrawn) = 100 - 40 = 60
        assertEq(vault.availableBalance(), 60e6);
    }

    // ─── Fuzz: notifyReceived delta ──────────────────────────────────────────────

    function testFuzz_NotifyReceivedDelta(uint256 amount) public {
        amount = bound(amount, 1, CAP);
        usdc.mint(address(vault), amount);
        vault.notifyReceived();
        assertEq(vault.totalReceived(), amount);
    }

    // ─── Fuzz: withdrawFor never exceeds claimable ───────────────────────────────

    function testFuzz_WithdrawForNeverExceedsClaimable(uint256 credited, uint256 attempt) public {
        credited = bound(credited, 1, 1e15);
        attempt  = bound(attempt, credited + 1, credited * 2 + 1);

        usdc.mint(address(vault), credited);
        vm.prank(registry);
        vault.credit(alice, credited);

        vm.prank(registry);
        vm.expectRevert(
            abi.encodeWithSelector(FeeVault.InsufficientClaimable.selector, credited, attempt)
        );
        vault.withdrawFor(alice, alice, attempt);
    }
}
