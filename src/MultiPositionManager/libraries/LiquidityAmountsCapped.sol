// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

library LiquidityAmountsCapped {
    function getLiquidityForAmountsCapped(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = _getLiquidityForAmount0Capped(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = _getLiquidityForAmount0Capped(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = _getLiquidityForAmount1Capped(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _getLiquidityForAmount1Capped(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function _getLiquidityForAmount0Capped(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        private
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        uint256 fullPrecision = FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96);
        liquidity = _capToUint128(fullPrecision);
    }

    function _getLiquidityForAmount1Capped(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 fullPrecision = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96);
        liquidity = _capToUint128(fullPrecision);
    }

    function _capToUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) return type(uint128).max;
        return uint128(value);
    }
}
