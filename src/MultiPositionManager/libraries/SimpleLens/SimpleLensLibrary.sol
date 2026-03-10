// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MultiPositionManager} from "../../MultiPositionManager.sol";
import {IMultiPositionManager} from "../../interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {RebalanceLogic} from "../RebalanceLogic.sol";
import {ILiquidityStrategy} from "../../strategies/ILiquidityStrategy.sol";
import {SimpleLensRatioUtils} from "./SimpleLensRatioUtils.sol";

/**
 * @title SimpleLensLibrary
 * @notice Shared logic for simulating deposits and rebalances in SimpleLens
 */
library SimpleLensLibrary {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Simulate deposit and rebalance to calculate expected positions and inMin
     * @param manager The MultiPositionManager contract
     * @param finalTotal0 Final amount of token0 after adding deposits
     * @param finalTotal1 Final amount of token1 after adding deposits
     * @param rebalanceParams Parameters for the rebalance (strategy, ticks, weights, etc.)
     * @param maxSlippageInMin Maximum slippage for minting new positions in basis points (10000 = 100%)
     * @return inMin Array of minimum amounts for depositing to new positions (slippage protection)
     * @return expectedPositions Array of PositionStats showing expected state after deposit + rebalance
     */
    function simulateDepositAndRebalance(
        MultiPositionManager manager,
        uint256 finalTotal0,
        uint256 finalTotal1,
        IMultiPositionManager.RebalanceParams memory rebalanceParams,
        uint256 maxSlippageInMin
    )
        external
        view
        returns (uint256[2][] memory inMin, SimpleLensRatioUtils.PositionStats[] memory expectedPositions)
    {
        // Generate ranges and liquidities
        (IMultiPositionManager.Range[] memory ranges, uint128[] memory liquidities, uint160 sqrtPriceX96) =
            _generateRangesAndLiquidities(manager, finalTotal0, finalTotal1, rebalanceParams);

        // Calculate base length: if limitWidth > 0, last 2 positions are limits
        uint256 baseLength = rebalanceParams.limitWidth > 0 && ranges.length >= 2 ? ranges.length - 2 : ranges.length;

        // Calculate expected positions
        expectedPositions = _buildExpectedPositions(ranges, liquidities, sqrtPriceX96, baseLength);

        // Calculate inMin
        inMin = _calculateInMinArray(expectedPositions, maxSlippageInMin);
    }

    function _generateRangesAndLiquidities(
        MultiPositionManager manager,
        uint256 finalTotal0,
        uint256 finalTotal1,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    )
        private
        view
        returns (IMultiPositionManager.Range[] memory ranges, uint128[] memory liquidities, uint160 sqrtPriceX96)
    {
        IPoolManager poolManager = manager.poolManager();
        PoolKey memory poolKey = manager.poolKey();
        int24 currentTick;
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
        int24 resolvedCenterTick =
            RebalanceLogic.resolveAndClampCenterTick(rebalanceParams.center, currentTick, poolKey.tickSpacing);

        // Build context
        RebalanceLogic.StrategyContext memory ctx;
        ctx.resolvedStrategy = rebalanceParams.strategy;
        ctx.center = resolvedCenterTick;
        ctx.tLeft = rebalanceParams.tLeft;
        ctx.tRight = rebalanceParams.tRight;
        ctx.strategy = ILiquidityStrategy(rebalanceParams.strategy);
        ctx.weight0 = rebalanceParams.weight0;
        ctx.weight1 = rebalanceParams.weight1;
        ctx.useCarpet = rebalanceParams.useCarpet;
        ctx.limitWidth = rebalanceParams.limitWidth;
        ctx.useAssetWeights = (rebalanceParams.weight0 == 0 && rebalanceParams.weight1 == 0);

        // Generate ranges
        (ranges, liquidities) =
            RebalanceLogic.generateRangesAndLiquiditiesWithPoolKey(poolKey, poolManager, ctx, finalTotal0, finalTotal1);
    }

    function _buildExpectedPositions(
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        uint160 sqrtPriceX96,
        uint256 baseLength
    ) private pure returns (SimpleLensRatioUtils.PositionStats[] memory expectedPositions) {
        expectedPositions = new SimpleLensRatioUtils.PositionStats[](ranges.length);

        for (uint256 i = 0; i < ranges.length; i++) {
            expectedPositions[i] = _calculatePositionStats(ranges[i], liquidities[i], sqrtPriceX96, i >= baseLength);
        }
    }

    function _calculateInMinArray(SimpleLensRatioUtils.PositionStats[] memory expectedPositions, uint256 maxSlippage)
        private
        pure
        returns (uint256[2][] memory inMin)
    {
        inMin = new uint256[2][](expectedPositions.length);

        for (uint256 i = 0; i < expectedPositions.length; i++) {
            uint256 slippageAdjustment0 = (expectedPositions[i].token0Quantity * maxSlippage) / 10000;
            uint256 slippageAdjustment1 = (expectedPositions[i].token1Quantity * maxSlippage) / 10000;

            inMin[i][0] = expectedPositions[i].token0Quantity > slippageAdjustment0
                ? expectedPositions[i].token0Quantity - slippageAdjustment0
                : 0;
            inMin[i][1] = expectedPositions[i].token1Quantity > slippageAdjustment1
                ? expectedPositions[i].token1Quantity - slippageAdjustment1
                : 0;
        }
    }

    /**
     * @dev Calculate position stats for a range
     * @param range The position range (tickLower, tickUpper)
     * @param liquidity The liquidity amount
     * @param sqrtPriceX96 Current sqrt price
     * @param isLimit Whether this is a limit position
     * @return stat Position statistics
     */
    function _calculatePositionStats(
        IMultiPositionManager.Range memory range,
        uint128 liquidity,
        uint160 sqrtPriceX96,
        bool isLimit
    ) private pure returns (SimpleLensRatioUtils.PositionStats memory stat) {
        stat.tickLower = range.lowerTick;
        stat.tickUpper = range.upperTick;
        stat.sqrtPriceLower = TickMath.getSqrtPriceAtTick(range.lowerTick);
        stat.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(range.upperTick);
        stat.liquidity = liquidity;

        (stat.token0Quantity, stat.token1Quantity) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, stat.sqrtPriceLower, stat.sqrtPriceUpper, liquidity);

        // Calculate value in token1
        stat.valueInToken1 = stat.token1Quantity
            + FullMath.mulDiv(stat.token0Quantity, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
        stat.isLimit = isLimit;
    }
}
