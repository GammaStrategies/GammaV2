// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {RebalanceLogic} from "../../src/MultiPositionManager/libraries/RebalanceLogic.sol";
import {IMultiPositionManager} from "../../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";

/// @notice Snapshot of pre-boundary-fix logic for regression testing
library RebalanceLogicOld {
    function calculateCurrentRangeExcess(
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range memory range,
        uint160 sqrtPriceX96
    ) internal pure returns (RebalanceLogic.ExcessData memory excess) {
        uint256 idx = data.currentRangeIndex;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(range.lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(range.upperTick);

        uint256 liquidityFrom1 = 0;
        if (sqrtPriceX96 > sqrtPriceLower) {
            liquidityFrom1 =
                FullMath.mulDiv(data.token1Allocations[idx], FixedPoint96.Q96, sqrtPriceX96 - sqrtPriceLower);
        }

        uint256 token0Needed = 0;
        if (sqrtPriceX96 < sqrtPriceUpper && liquidityFrom1 > 0) {
            token0Needed = FullMath.mulDiv(
                liquidityFrom1,
                sqrtPriceUpper - sqrtPriceX96,
                FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96)
            );
        }

        uint256 actualLiquidity;
        if (data.token0Allocations[idx] < token0Needed) {
            if (sqrtPriceX96 < sqrtPriceUpper) {
                uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
                actualLiquidity =
                    FullMath.mulDiv(data.token0Allocations[idx], intermediate, sqrtPriceUpper - sqrtPriceX96);
            } else {
                actualLiquidity = 0;
            }
        } else {
            actualLiquidity = liquidityFrom1;
        }

        (excess.actualToken0, excess.actualToken1) =
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                sqrtPriceLower,
                sqrtPriceUpper,
                _capLiquidity(actualLiquidity)
            );

        excess.excessToken0 =
            data.token0Allocations[idx] > excess.actualToken0 ? data.token0Allocations[idx] - excess.actualToken0 : 0;
        excess.excessToken1 =
            data.token1Allocations[idx] > excess.actualToken1 ? data.token1Allocations[idx] - excess.actualToken1 : 0;
    }

    function mintFromAllocations(
        uint128[] memory liquidities,
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range[] memory baseRanges,
        uint160 sqrtPriceX96
    ) internal pure {
        uint256 rangesLength = baseRanges.length;

        for (uint256 i = 0; i < rangesLength;) {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(baseRanges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(baseRanges[i].upperTick);

            if (baseRanges[i].upperTick <= data.currentTick) {
                if (sqrtPriceUpper > sqrtPriceLower && data.token1Allocations[i] > 0) {
                    uint256 liquidity = FullMath.mulDiv(
                        data.token1Allocations[i],
                        FixedPoint96.Q96,
                        sqrtPriceUpper - sqrtPriceLower
                    );
                    liquidities[i] = _capLiquidity(liquidity);
                } else {
                    liquidities[i] = 0;
                }
            } else if (baseRanges[i].lowerTick > data.currentTick) {
                if (sqrtPriceUpper > sqrtPriceLower && data.token0Allocations[i] > 0) {
                    uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceLower, FixedPoint96.Q96);
                    uint256 liquidity =
                        FullMath.mulDiv(data.token0Allocations[i], intermediate, sqrtPriceUpper - sqrtPriceLower);
                    liquidities[i] = _capLiquidity(liquidity);
                } else {
                    liquidities[i] = 0;
                }
            } else {
                uint256 liquidityFrom1 = 0;
                if (sqrtPriceX96 > sqrtPriceLower && data.token1Allocations[i] > 0) {
                    liquidityFrom1 =
                        FullMath.mulDiv(data.token1Allocations[i], FixedPoint96.Q96, sqrtPriceX96 - sqrtPriceLower);
                }

                uint256 token0Needed = 0;
                if (sqrtPriceX96 < sqrtPriceUpper && liquidityFrom1 > 0) {
                    token0Needed = FullMath.mulDiv(
                        liquidityFrom1,
                        sqrtPriceUpper - sqrtPriceX96,
                        FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96)
                    );
                }

                if (data.token0Allocations[i] < token0Needed && data.token0Allocations[i] > 0) {
                    if (sqrtPriceX96 < sqrtPriceUpper) {
                        uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
                        uint256 liquidity =
                            FullMath.mulDiv(data.token0Allocations[i], intermediate, sqrtPriceUpper - sqrtPriceX96);
                        liquidities[i] = _capLiquidity(liquidity);
                    } else {
                        liquidities[i] = 0;
                    }
                } else {
                    liquidities[i] = _capLiquidity(liquidityFrom1);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _capLiquidity(uint256 liquidity) private pure returns (uint128) {
        return liquidity > type(uint128).max ? type(uint128).max : uint128(liquidity);
    }
}

contract RebalanceLogicOldHarness {
    function calculateCurrentRangeExcess(
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range memory range,
        uint160 sqrtPriceX96
    ) external pure returns (RebalanceLogic.ExcessData memory) {
        return RebalanceLogicOld.calculateCurrentRangeExcess(data, range, sqrtPriceX96);
    }

    function mintFromAllocations(
        uint128[] memory liquidities,
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range[] memory baseRanges,
        uint160 sqrtPriceX96
    ) external pure returns (uint128[] memory) {
        RebalanceLogicOld.mintFromAllocations(liquidities, data, baseRanges, sqrtPriceX96);
        return liquidities;
    }
}
