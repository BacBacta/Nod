// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILaunchpadAdapter} from "./ILaunchpadAdapter.sol";
import {IMintPlus, IMintPlusLocker} from "./external/IBullcheese.sol";
import {IUniswapV3PoolMinimal} from "./external/IUniswapV3.sol";

/**
 * @title  BullcheeseAdapter
 * @notice ILaunchpadAdapter for Bullcheese (Team Finance MintPlus) on Arc.
 *
 * @dev    Bullcheese has no fee-recipient field: each token's LP position sits in a
 *         per-token locker, and `collectFees()` pays the creator share (75% of the 1%
 *         swap fee, in USDC and in the token) to the locker's owner. To route a token
 *         through Nod, the creator calls `locker.transferOwnership(vault)` with the
 *         predicted vault address, then registers; the Registry makes the vault accept.
 *
 *         Once the vault owns the locker nobody else can collect, withdraw or transfer:
 *         FeeVault only ever calls `acceptOwnership()` and `collectFees()` on it, so the
 *         liquidity stays locked for good.
 */
contract BullcheeseAdapter is ILaunchpadAdapter {
    error ZeroAddress();

    IMintPlus public immutable mintPlus;
    address public immutable usdc;

    constructor(address _mintPlus, address _usdc) {
        if (_mintPlus == address(0) || _usdc == address(0)) revert ZeroAddress();
        mintPlus = IMintPlus(_mintPlus);
        usdc = _usdc;
    }

    /// @inheritdoc ILaunchpadAdapter
    function verifyFeeRecipient(address token, address vault) external view returns (bool) {
        (address pool, address locker,,) = mintPlus.deploymentInfo(token);
        if (locker == address(0) || !_pairsWithUsdc(pool, token)) return false;
        return IMintPlusLocker(locker).owner() == vault
            && IMintPlusLocker(locker).pendingOwner() == address(0);
    }

    /// @inheritdoc ILaunchpadAdapter
    function feeSource(address token) external view returns (address) {
        (, address locker,,) = mintPlus.deploymentInfo(token);
        return locker;
    }

    /// @inheritdoc ILaunchpadAdapter
    function usdcPool(address token) external view returns (address) {
        (address pool,,,) = mintPlus.deploymentInfo(token);
        return _pairsWithUsdc(pool, token) ? pool : address(0);
    }

    function _pairsWithUsdc(address pool, address token) internal view returns (bool) {
        if (pool == address(0)) return false;
        address t0 = IUniswapV3PoolMinimal(pool).token0();
        address t1 = IUniswapV3PoolMinimal(pool).token1();
        return (t0 == usdc && t1 == token) || (t0 == token && t1 == usdc);
    }
}
