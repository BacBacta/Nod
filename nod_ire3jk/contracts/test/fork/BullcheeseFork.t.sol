// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Registry} from "../../Registry.sol";
import {FeeVault} from "../../FeeVault.sol";
import {FeeVaultFactory} from "../../FeeVaultFactory.sol";
import {IdentityAttestor} from "../../IdentityAttestor.sol";
import {BullcheeseAdapter} from "../../BullcheeseAdapter.sol";
import {IMintPlus, IMintPlusLocker} from "../../external/IBullcheese.sol";
import {ISwapRouter02, IUniswapV3PoolMinimal} from "../../external/IUniswapV3.sol";
import {TwapQuote} from "../../libraries/TwapQuote.sol";

/// @dev Plain ERC-20 etched over Arc's USDC for the fork: Arc's USDC moves balances
///      through a native precompile (0x1800…) that Foundry's EVM does not implement.
contract ForkUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) { return 6; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/**
 * @notice End-to-end against the real Bullcheese contracts on an Arc mainnet fork:
 *         a live token's locker is handed to a Nod vault, real swaps through Uniswap
 *         generate fees, Nod collects them, converts the token side to USDC under the
 *         TWAP bound, and the creator claims.
 *
 *         Runs only with ARC_MAINNET_RPC set, e.g.
 *         ARC_MAINNET_RPC=https://rpc.mainnet.arc.io forge test --match-contract BullcheeseFork
 */
contract BullcheeseForkTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant MINT_PLUS = 0x16D4c13aD2A23288AA9b9384F24084edC8CBeF41;
    address internal constant SWAP_ROUTER = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    /// A token launched on Bullcheese (USDC pair, 1% pool).
    address internal constant TOKEN = 0x9B61F45975CeFcC2B9E6F874A6325194AD310396;
    uint256 internal constant FORK_BLOCK = 22_920_000;

    Registry internal registry;
    FeeVaultFactory internal factory;
    IdentityAttestor internal attestor;
    BullcheeseAdapter internal adapter;
    IUniswapV3PoolMinimal internal pool;
    IMintPlusLocker internal locker;
    address internal creator;
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");
    uint256 internal attesterKey;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        (address p, address l,,) = IMintPlus(MINT_PLUS).deploymentInfo(TOKEN);
        pool = IUniswapV3PoolMinimal(p);
        locker = IMintPlusLocker(l);
        creator = locker.owner();

        // Swap in a storage-based USDC, preserving the pool's real USDC reserves.
        uint256 poolUsdc = IERC20(USDC).balanceOf(p);
        vm.etch(USDC, type(ForkUSDC).runtimeCode);
        deal(USDC, p, poolUsdc);
        deal(USDC, trader, 50_000e6);

        address attesterAddr;
        (attesterAddr, attesterKey) = makeAddrAndKey("attester");
        factory = new FeeVaultFactory(address(this), USDC, 0);
        attestor = new IdentityAttestor(address(this), attesterAddr, address(this));
        registry = new Registry(
            USDC, address(factory), address(attestor), makeAddr("treasury"), makeAddr("buyback"),
            address(this), address(this), address(this), 1000, makeAddr("fallback")
        );
        adapter = new BullcheeseAdapter(MINT_PLUS, USDC);
        factory.setRegistry(address(registry));
        registry.setAdapterWhitelist(address(adapter), true);
        registry.setSwapRouter(SWAP_ROUTER);
        registry.grantRole(registry.KEEPER_ROLE(), keeper);
    }

    function _attest(bytes32 platform, bytes32 id, address wallet) internal {
        uint48 expiry = uint48(block.timestamp + 1 days);
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = attestor.eip712Domain();
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifying
        ));
        bytes32 structHash = keccak256(abi.encode(attestor.ATTESTATION_TYPEHASH(), platform, id, wallet, expiry, bytes32("n")));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        attestor.attest(platform, id, wallet, expiry, bytes32("n"), abi.encodePacked(r, s, v));
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        vm.startPrank(trader);
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
        ISwapRouter02(SWAP_ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, fee: pool.fee(), recipient: trader,
            amountIn: amountIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
    }

    function test_Fork_FullBullcheeseFlow() public {
        bytes32 platform = keccak256("x");
        bytes32 id = attestor.creatorIdOf(platform, "fork-creator");
        _attest(platform, id, creator);
        vm.warp(block.timestamp + 7 days + 1);

        // 1. Creator hands the real locker to the predicted vault and registers.
        (address predicted,) = factory.predictVaultAddress(creator, TOKEN);
        Registry.SplitInput[] memory splits = new Registry.SplitInput[](1);
        splits[0] = Registry.SplitInput({recipient: creator, bps: 10_000});
        vm.startPrank(creator);
        (bool ok,) = address(locker).call(abi.encodeWithSignature("transferOwnership(address)", predicted));
        assertTrue(ok);
        registry.registerToken(TOKEN, address(adapter), id, splits, makeAddr("fallback"), bytes32("bullcheese"));
        registry.accept(TOKEN);
        registry.acceptSplit(TOKEN, 0);
        vm.stopPrank();
        FeeVault vault = FeeVault(payable(registry.vaultOf(TOKEN)));
        assertEq(locker.owner(), address(vault));
        registry.prepareSwapOracle(TOKEN, 50);

        // 2. Real trading generates fees on both sides of the pool.
        _swap(USDC, TOKEN, 5_000e6);
        _swap(TOKEN, USDC, IERC20(TOKEN).balanceOf(trader) / 2);
        vm.warp(block.timestamp + 11 minutes);
        vm.roll(block.number + 1);

        // 3. Anyone collects: USDC is distributed, token fees wait in the vault.
        registry.collectFees(TOKEN);
        uint256 claimableUsdc = vault.claimable(creator);
        uint256 tokenFees = IERC20(TOKEN).balanceOf(address(vault));
        assertGt(claimableUsdc, 0, "USDC fees credited");
        assertGt(tokenFees, 0, "token fees collected");
        emit log_named_uint("USDC credited from buys", claimableUsdc);
        emit log_named_uint("token fees held", tokenFees);

        // 4. Keeper converts the token fees at no worse than TWAP - 3%.
        uint256 twapOut = TwapQuote.quote(pool, registry.SWAP_TWAP_WINDOW(), TOKEN, USDC, uint128(tokenFees));
        uint256 floor = (twapOut * 9_700) / 10_000;
        vm.prank(keeper);
        registry.swapTokenFees(TOKEN, tokenFees, floor);
        assertEq(IERC20(TOKEN).balanceOf(address(vault)), 0);
        assertGt(vault.claimable(creator), claimableUsdc);
        emit log_named_uint("claimable after swap", vault.claimable(creator));

        // 5. The former owner can no longer collect; the lock stays with the vault.
        vm.prank(creator);
        vm.expectRevert();
        IMintPlusLocker(address(locker)).collectFees();
        assertEq(locker.owner(), address(vault));
    }
}
