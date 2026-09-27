// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockUniswapRouter
 * @notice Stub SwapRouter02 (no deadline field) for testing BuybackModule.
 */
contract MockUniswapRouter {
    using SafeERC20 for IERC20;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    uint256 public amountOutOverride;
    address public nodToken;

    constructor(uint256 _amountOut, address _nodToken) {
        amountOutOverride = _amountOut;
        nodToken = _nodToken;
    }

    function setAmountOut(uint256 amount) external {
        amountOutOverride = amount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Pull the tokenIn from caller
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Send nodToken to recipient
        if (nodToken != address(0) && amountOutOverride > 0) {
            IERC20(nodToken).transfer(params.recipient, amountOutOverride);
        }
        return amountOutOverride;
    }
}
