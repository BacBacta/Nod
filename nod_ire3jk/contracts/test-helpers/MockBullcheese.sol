// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test stand-in for MintPlus.deploymentInfo.
contract MockMintPlus {
    mapping(address => address) public poolOf;
    mapping(address => address) public lockerOf;

    function set(address token, address pool, address locker) external {
        poolOf[token] = pool;
        lockerOf[token] = locker;
    }

    function deploymentInfo(address token) external view returns (address, address, uint256, uint256) {
        return (poolOf[token], lockerOf[token], 1, 1);
    }
}

/// @notice Test stand-in for a MintPlus LP locker: Ownable2Step, owner-only collectFees
///         paying preset amounts of both pool tokens to the owner.
contract MockLocker is Ownable2Step {
    MockERC20 public immutable usdc;
    MockERC20 public immutable token;
    uint256 public usdcFees;
    uint256 public tokenFees;
    uint256 public withdrawCalls;

    constructor(address initialOwner, MockERC20 _usdc, MockERC20 _token) Ownable(initialOwner) {
        usdc = _usdc;
        token = _token;
    }

    function accrue(uint256 u, uint256 t) external {
        usdcFees += u;
        tokenFees += t;
    }

    function collectFees() external onlyOwner {
        if (usdcFees > 0) usdc.mint(owner(), usdcFees);
        if (tokenFees > 0) token.mint(owner(), tokenFees);
        usdcFees = 0;
        tokenFees = 0;
    }

    function withdrawLiquidityLock() external onlyOwner {
        withdrawCalls++;
    }
}

/// @notice Uniswap v3 pool stand-in with a fixed TWAP tick.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee = 10_000;
    int24 public twapTick;
    uint16 public cardinalityNext;
    bool public tooYoung;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setTwapTick(int24 t) external { twapTick = t; }
    function setFee(uint24 f) external { fee = f; }
    function setTooYoung(bool v) external { tooYoung = v; }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory cumulatives, uint160[] memory perLiquidity)
    {
        require(!tooYoung, "OLD");
        cumulatives = new int56[](2);
        perLiquidity = new uint160[](2);
        cumulatives[0] = 1_000_000;
        cumulatives[1] = 1_000_000 + int56(twapTick) * int56(uint56(secondsAgos[0]));
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        cardinalityNext = n;
    }
}

/// @notice SwapRouter02 stand-in: pays out `rateBps` of amountIn in tokenOut (1:1 raw units at 10_000).
contract MockSwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    uint256 public rateBps = 10_000;

    function setRateBps(uint256 r) external { rateBps = r; }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * rateBps) / 10_000;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}
