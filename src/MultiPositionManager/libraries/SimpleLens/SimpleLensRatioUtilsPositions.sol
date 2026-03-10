// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MultiPositionManager} from "../../MultiPositionManager.sol";
import {IMultiPositionManager} from "../../interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {DepositRatioLib} from "../DepositRatioLib.sol";
import {PoolManagerUtils} from "../PoolManagerUtils.sol";
import {LiquidityAmountsCapped} from "../LiquidityAmountsCapped.sol";
import {SimpleLensRatioUtils} from "./SimpleLensRatioUtils.sol";

/**
 * @title SimpleLensRatioUtilsPositions
 * @notice Position stats helpers split from SimpleLensRatioUtils to reduce runtime size.
 */
library SimpleLensRatioUtilsPositions {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function calculateExpectedPositionsAfterDeposit(
        MultiPositionManager manager,
        IMultiPositionManager.Range[] memory ranges,
        IMultiPositionManager.PositionData[] memory positionData,
        uint256 deposit0,
        uint256 deposit1
    ) external view returns (SimpleLensRatioUtils.PositionStats[] memory expectedPositions) {
        expectedPositions = new SimpleLensRatioUtils.PositionStats[](ranges.length);

        SimpleLensRatioUtils.DepositCalculationContext memory ctx;
        PoolKey memory poolKey = manager.poolKey();
        IPoolManager pm = manager.poolManager();
        (ctx.sqrtPriceX96,,,) = pm.getSlot0(poolKey.toId());
        ctx.poolKey = poolKey;
        ctx.pm = pm;

        uint256 baseLen = manager.basePositionsLength();

        for (uint256 i = 0; i < ranges.length; i++) {
            if (positionData[i].liquidity == 0) continue;
            ctx.totalToken0InPositions += positionData[i].amount0;
            ctx.totalToken1InPositions += positionData[i].amount1;
        }

        if (ctx.totalToken0InPositions == 0 && ctx.totalToken1InPositions > 0) {
            ctx.amount1ForPositions = deposit1;
        } else if (ctx.totalToken1InPositions == 0 && ctx.totalToken0InPositions > 0) {
            ctx.amount0ForPositions = deposit0;
        } else if (ctx.totalToken0InPositions > 0 && ctx.totalToken1InPositions > 0) {
            (ctx.amount0ForPositions, ctx.amount1ForPositions) = DepositRatioLib.getRatioAmounts(
                ctx.totalToken0InPositions, ctx.totalToken1InPositions, deposit0, deposit1
            );
        }

        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) continue;
            expectedPositions[i] = _buildPositionStats(ctx, ranges[i], positionData[i], i >= baseLen);
        }
    }

    function getPositionStats(MultiPositionManager manager)
        external
        view
        returns (SimpleLensRatioUtils.PositionStats[] memory stats)
    {
        (IMultiPositionManager.Range[] memory ranges,) = manager.getPositions();
        stats = new SimpleLensRatioUtils.PositionStats[](ranges.length);

        IPoolManager pm = manager.poolManager();
        PoolKey memory poolKey = manager.poolKey();
        uint256 baseLen = manager.basePositionsLength();
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(poolKey.toId());

        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) continue;

            (uint128 liquidity, uint256 amount0, uint256 amount1,,) =
                PoolManagerUtils.getAmountsOf(pm, poolKey, ranges[i]);

            uint256 token0ValueInToken1 =
                FullMath.mulDiv(amount0, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);

            stats[i] = SimpleLensRatioUtils.PositionStats({
                tickLower: ranges[i].lowerTick,
                tickUpper: ranges[i].upperTick,
                sqrtPriceLower: TickMath.getSqrtPriceAtTick(ranges[i].lowerTick),
                sqrtPriceUpper: TickMath.getSqrtPriceAtTick(ranges[i].upperTick),
                liquidity: liquidity,
                token0Quantity: amount0,
                token1Quantity: amount1,
                valueInToken1: amount1 + token0ValueInToken1,
                isLimit: i >= baseLen
            });
        }
    }

    function _buildPositionStats(
        SimpleLensRatioUtils.DepositCalculationContext memory ctx,
        IMultiPositionManager.Range memory range,
        IMultiPositionManager.PositionData memory posData,
        bool isLimit
    ) private view returns (SimpleLensRatioUtils.PositionStats memory stats) {
        uint256 newAmount0;
        uint256 newAmount1;

        {
            uint256 additionalAmount0;
            uint256 additionalAmount1;

            if (posData.liquidity > 0) {
                if (ctx.totalToken0InPositions > 0) {
                    additionalAmount0 = (ctx.amount0ForPositions * posData.amount0) / ctx.totalToken0InPositions;
                }
                if (ctx.totalToken1InPositions > 0) {
                    additionalAmount1 = (ctx.amount1ForPositions * posData.amount1) / ctx.totalToken1InPositions;
                }
            }

            (uint256 currentAmount0, uint256 currentAmount1) =
                PoolManagerUtils.getAmountsForLiquidity(ctx.pm, ctx.poolKey, range, uint128(posData.liquidity));

            newAmount0 = currentAmount0 + additionalAmount0;
            newAmount1 = currentAmount1 + additionalAmount1;
        }

        {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(range.lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(range.upperTick);

            stats = SimpleLensRatioUtils.PositionStats({
                tickLower: range.lowerTick,
                tickUpper: range.upperTick,
                sqrtPriceLower: sqrtPriceLower,
                sqrtPriceUpper: sqrtPriceUpper,
                liquidity: LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    ctx.sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, newAmount0, newAmount1
                ),
                token0Quantity: newAmount0,
                token1Quantity: newAmount1,
                valueInToken1: newAmount1
                    + FullMath.mulDiv(newAmount0, uint256(ctx.sqrtPriceX96) * uint256(ctx.sqrtPriceX96), 1 << 192),
                isLimit: isLimit
            });
        }
    }
}
