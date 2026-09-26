// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IUniswapV3PoolMinimal} from "../external/IUniswapV3.sol";

/**
 * @title  TwapQuote
 * @notice Time-weighted average price quote from a Uniswap v3 pool, following Uniswap's
 *         OracleLibrary (consult + getQuoteAtTick). Reverts (pool "OLD") if the pool has
 *         no observation at least `window` seconds old; grow the pool's observation
 *         cardinality first.
 */
library TwapQuote {
    /// @return quote Amount of `quoteToken` worth `baseAmount` of `baseToken` at the TWAP.
    function quote(
        IUniswapV3PoolMinimal pool,
        uint32 window,
        address baseToken,
        address quoteToken,
        uint128 baseAmount
    ) internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory cumulatives,) = pool.observe(secondsAgos);

        int56 delta = cumulatives[1] - cumulatives[0];
        int24 tick = int24(delta / int56(uint56(window)));
        // Round toward negative infinity, as OracleLibrary.consult does.
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--;

        return quoteAtTick(tick, baseAmount, baseToken, quoteToken);
    }

    function quoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseToken < quoteToken
            ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
            : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
    }
}
