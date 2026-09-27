// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeVaultFactory} from "../FeeVaultFactory.sol";
import {FeeVault} from "../FeeVault.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract FeeVaultFactoryTest is Test {
    MockERC20        internal usdc;
    FeeVaultFactory  internal factory;

    address internal admin    = makeAddr("admin");
    address internal registry = makeAddr("registry");
    address internal deployer = makeAddr("deployer");
    address internal token    = makeAddr("token");
    address internal alice    = makeAddr("alice");

    uint256 internal constant DEFAULT_CAP = 1_000_000e6;

    function setUp() public {
        usdc    = new MockERC20("Mock USDC", "mUSDC", 6);
        factory = new FeeVaultFactory(admin, address(usdc), DEFAULT_CAP);

        vm.prank(admin);
        factory.setRegistry(registry);
    }

    // ─── setRegistry ────────────────────────────────────────────────────────────

    function test_SetRegistry_OnlyAdmin() public {
        FeeVaultFactory f2 = new FeeVaultFactory(admin, address(usdc), 0);
        vm.prank(alice);
        vm.expectRevert(FeeVaultFactory.NotAdmin.selector);
        f2.setRegistry(registry);
    }

    function test_SetRegistry_SecondCallReverts() public {
        vm.prank(admin);
        vm.expectRevert(FeeVaultFactory.RegistryAlreadySet.selector);
        factory.setRegistry(alice);
    }

    function test_SetRegistry_ZeroAddressReverts() public {
        FeeVaultFactory f2 = new FeeVaultFactory(admin, address(usdc), 0);
        vm.prank(admin);
        vm.expectRevert(FeeVaultFactory.ZeroAddress.selector);
        f2.setRegistry(address(0));
    }

    // ─── deployVault ────────────────────────────────────────────────────────────

    function test_DeployVault_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(FeeVaultFactory.NotRegistry.selector);
        factory.deployVault(deployer, token);
    }

    function test_DeployVault_ReturnsCorrectAddress() public {
        // Predict before deploy
        (address predicted,) = factory.predictVaultAddress(deployer, token);

        vm.prank(registry);
        (address vault,) = factory.deployVault(deployer, token);

        assertEq(vault, predicted, "deployed address must match predicted");
    }

    function test_DeployVault_MatchesPredictVaultAddress() public {
        (address predicted, bytes32 saltPredicted) = factory.predictVaultAddress(deployer, token);

        vm.prank(registry);
        (address vault, bytes32 usedSalt) = factory.deployVault(deployer, token);

        assertEq(vault, predicted);
        assertEq(usedSalt, saltPredicted);
    }

    function test_DeployVault_SaltKeccakOfDeployerAndToken() public {
        bytes32 expected = keccak256(abi.encodePacked(deployer, token));

        vm.prank(registry);
        (, bytes32 usedSalt) = factory.deployVault(deployer, token);

        assertEq(usedSalt, expected);
    }

    function test_DeployVault_NonceIncrements() public {
        assertEq(factory.deployerNonce(deployer), 0);

        vm.prank(registry);
        factory.deployVault(deployer, token);
        assertEq(factory.deployerNonce(deployer), 1);

        address token2 = makeAddr("token2");
        vm.prank(registry);
        factory.deployVault(deployer, token2);
        assertEq(factory.deployerNonce(deployer), 2);
    }

    function test_DeployVault_EmitsEvent() public {
        uint256 nonce = factory.deployerNonce(deployer);
        bytes32 salt  = keccak256(abi.encodePacked(deployer, token));
        (address predicted,) = factory.predictVaultAddress(deployer, token);

        vm.expectEmit(true, true, true, true, address(factory));
        emit FeeVaultFactory.VaultDeployed(token, predicted, salt, deployer, nonce);

        vm.prank(registry);
        factory.deployVault(deployer, token);
    }

    function test_DeployVault_VaultHasCorrectImmutables() public {
        vm.prank(registry);
        (address vaultAddr,) = factory.deployVault(deployer, token);

        FeeVault v = FeeVault(payable(vaultAddr));
        assertEq(address(v.USDC()), address(usdc));
        assertEq(v.factory(), address(factory));
        assertEq(v.token(), token);
        assertEq(v.registry(), registry);
        assertEq(v.depositCap(), DEFAULT_CAP);
    }

    // ─── setDefaultDepositCap ────────────────────────────────────────────────────

    function test_SetDefaultDepositCap_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(FeeVaultFactory.NotRegistry.selector);
        factory.setDefaultDepositCap(999e6);
    }

    function test_SetDefaultDepositCap_UpdatesValue() public {
        vm.prank(registry);
        factory.setDefaultDepositCap(500e6);
        assertEq(factory.defaultDepositCap(), 500e6);
    }

    function test_SetDefaultDepositCap_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit FeeVaultFactory.DepositCapUpdated(DEFAULT_CAP, 500e6);

        vm.prank(registry);
        factory.setDefaultDepositCap(500e6);
    }

    // ─── Deterministic address: different deployers get different vaults ─────────

    function test_DifferentDeployersGetDifferentVaults() public {
        address deployer2 = makeAddr("deployer2");

        vm.prank(registry);
        (address v1,) = factory.deployVault(deployer, token);

        address token2 = makeAddr("token2");
        vm.prank(registry);
        (address v2,) = factory.deployVault(deployer2, token2);

        assertTrue(v1 != v2, "different deployers must yield different vaults");
    }
}
