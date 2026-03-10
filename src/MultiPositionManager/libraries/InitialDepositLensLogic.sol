// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {ILiquidityStrategy} from "../strategies/ILiquidityStrategy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {RebalanceLogic} from "./RebalanceLogic.sol";
import {SimpleLensInMin} from "./SimpleLens/SimpleLensInMin.sol";
import {SimpleLensRatioUtils} from "./SimpleLens/SimpleLensRatioUtils.sol";

library InitialDepositLensLogic {
    struct DepositParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        bool isToken0;
        uint256 amount;
        uint256 maxSlippageBps;
    }

    struct CustomDepositParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        uint256 deposit0;
        uint256 deposit1;
        uint256 maxSlippageBps;
    }

    struct WeightCallParams {
        address strategy;
        int24[] lowerTicks;
        int24[] upperTicks;
        int24 currentTick;
        int24 center;
        uint24 tLeft;
        uint24 tRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        int24 tickSpacing;
        bool useAssetWeights;
    }

    function getAmountsForInitialDepositAndPreviewRebalance(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        DepositParams calldata params
    )
        external
        view
        returns (uint256 otherAmount, uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview)
    {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 resolvedCenterTick = _resolveCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);

        otherAmount = SimpleLensInMin.calculateOtherAmountInline(
            poolManager,
            poolKey,
            SimpleLensInMin.CalculateOtherAmountParams({
                strategyAddress: params.strategyAddress,
                resolvedCenterTick: resolvedCenterTick,
                ticksLeft: params.ticksLeft,
                ticksRight: params.ticksRight,
                limitWidth: params.limitWidth,
                weight0: params.weight0,
                weight1: params.weight1,
                useCarpet: params.useCarpet,
                sqrtPriceX96: sqrtPriceX96,
                isToken0: params.isToken0,
                amount: params.amount
            })
        );

        IMultiPositionManager.Range[] memory allRanges;
        uint128[] memory allLiquidities;
        (allRanges, allLiquidities, inMin) =
            _generateAllRangesAndInMin(poolKey, params, resolvedCenterTick, currentTick, sqrtPriceX96, otherAmount);

        preview.strategy = params.strategyAddress;
        preview.centerTick = resolvedCenterTick;
        preview.ticksLeft = params.ticksLeft;
        preview.ticksRight = params.ticksRight;
        preview.ranges = allRanges;
        preview.liquidities = allLiquidities;

        _calculateExpectedTotalsWithPoolKey(poolKey, sqrtPriceX96, preview, params.limitWidth);
    }

    function previewCustomInitialDepositAndRebalance(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        CustomDepositParams calldata params
    ) external view returns (uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview) {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 resolvedCenterTick = _resolveCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);

        IMultiPositionManager.Range[] memory allRanges;
        uint128[] memory allLiquidities;
        (allRanges, allLiquidities, inMin) =
            _generateAllRangesAndInMinCustom(poolKey, params, resolvedCenterTick, currentTick, sqrtPriceX96);

        preview.strategy = params.strategyAddress;
        preview.centerTick = resolvedCenterTick;
        preview.ticksLeft = params.ticksLeft;
        preview.ticksRight = params.ticksRight;
        preview.ranges = allRanges;
        preview.liquidities = allLiquidities;

        _calculateExpectedTotalsWithPoolKey(poolKey, sqrtPriceX96, preview, params.limitWidth);
    }

    function getAmountsForInitialDepositWithSwapAndPreview(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        SimpleLensInMin.InitialDepositWithSwapParams calldata params
    )
        external
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            SimpleLensInMin.RebalancePreview memory preview
        )
    {
        return _calculateSwapAndPreviewWithSqrtPrice(poolKey, sqrtPriceX96, params);
    }

    function _resolveCenterTick(int24 centerTick, int24 currentTick, int24 tickSpacing) private pure returns (int24) {
        return RebalanceLogic.resolveAndClampCenterTick(centerTick, currentTick, tickSpacing);
    }

    function _generateAllRangesAndInMinCustom(
        PoolKey memory poolKey,
        CustomDepositParams calldata params,
        int24 resolvedCenterTick,
        int24 currentTick,
        uint160 sqrtPriceX96
    )
        private
        view
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        IMultiPositionManager.Range[] memory baseRanges;
        uint128[] memory baseLiquidities;

        {
            RebalanceLogic.StrategyContext memory ctx = RebalanceLogic.StrategyContext({
                resolvedStrategy: params.strategyAddress,
                center: resolvedCenterTick,
                tLeft: params.ticksLeft,
                tRight: params.ticksRight,
                strategy: ILiquidityStrategy(params.strategyAddress),
                weight0: params.weight0,
                weight1: params.weight1,
                useCarpet: params.useCarpet,
                limitWidth: params.limitWidth,
                useAssetWeights: (params.weight0 == 0 && params.weight1 == 0)
            });

            (baseRanges, baseLiquidities) = _generateRangesAndLiquiditiesWithSqrtPrice(
                poolKey, ctx, params.deposit0, params.deposit1, sqrtPriceX96
            );
        }

        {
            SimpleLensInMin.LimitPositionsParams memory limitParams = SimpleLensInMin.LimitPositionsParams({
                limitWidth: params.limitWidth,
                currentTick: currentTick,
                tickSpacing: poolKey.tickSpacing,
                maxSlippageBps: params.maxSlippageBps,
                sqrtPriceX96: sqrtPriceX96,
                totalAmount0: params.deposit0,
                totalAmount1: params.deposit1
            });
            (allRanges, allLiquidities, inMin) =
                SimpleLensInMin.addLimitPositionsAndCalculateInMin(baseRanges, baseLiquidities, limitParams);
        }
    }

    function _generateAllRangesAndInMin(
        PoolKey memory poolKey,
        DepositParams calldata params,
        int24 resolvedCenterTick,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint256 otherAmount
    )
        private
        view
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        IMultiPositionManager.Range[] memory baseRanges;
        uint128[] memory baseLiquidities;
        uint256 amount0 = params.isToken0 ? params.amount : otherAmount;
        uint256 amount1 = params.isToken0 ? otherAmount : params.amount;

        {
            RebalanceLogic.StrategyContext memory ctx = RebalanceLogic.StrategyContext({
                resolvedStrategy: params.strategyAddress,
                center: resolvedCenterTick,
                tLeft: params.ticksLeft,
                tRight: params.ticksRight,
                strategy: ILiquidityStrategy(params.strategyAddress),
                weight0: params.weight0,
                weight1: params.weight1,
                useCarpet: params.useCarpet,
                limitWidth: params.limitWidth,
                useAssetWeights: (params.weight0 == 0 && params.weight1 == 0)
            });

            (baseRanges, baseLiquidities) =
                _generateRangesAndLiquiditiesWithSqrtPrice(poolKey, ctx, amount0, amount1, sqrtPriceX96);
        }

        {
            SimpleLensInMin.LimitPositionsParams memory limitParams = SimpleLensInMin.LimitPositionsParams({
                limitWidth: params.limitWidth,
                currentTick: currentTick,
                tickSpacing: poolKey.tickSpacing,
                maxSlippageBps: params.maxSlippageBps,
                sqrtPriceX96: sqrtPriceX96,
                totalAmount0: amount0,
                totalAmount1: amount1
            });
            (allRanges, allLiquidities, inMin) =
                SimpleLensInMin.addLimitPositionsAndCalculateInMin(baseRanges, baseLiquidities, limitParams);
        }
    }

    function _calculateExpectedTotalsWithPoolKey(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        SimpleLensInMin.RebalancePreview memory preview,
        uint24 limitWidth
    ) private pure {
        preview.expectedPositions = new SimpleLensRatioUtils.PositionStats[](preview.ranges.length);
        preview.expectedTotal0 = 0;
        preview.expectedTotal1 = 0;

        uint256 baseLength =
            limitWidth > 0 && preview.ranges.length >= 2 ? preview.ranges.length - 2 : preview.ranges.length;

        for (uint256 i = 0; i < preview.ranges.length; i++) {
            IMultiPositionManager.Position memory pos = IMultiPositionManager.Position({
                poolKey: poolKey,
                lowerTick: preview.ranges[i].lowerTick,
                upperTick: preview.ranges[i].upperTick
            });

            preview.expectedPositions[i] =
                _calculatePositionStats(pos, preview.liquidities[i], sqrtPriceX96, i >= baseLength);

            preview.expectedTotal0 += preview.expectedPositions[i].token0Quantity;
            preview.expectedTotal1 += preview.expectedPositions[i].token1Quantity;
        }
    }

    function _calculatePositionStats(
        IMultiPositionManager.Position memory position,
        uint128 liquidity,
        uint160 sqrtPriceX96,
        bool isLimit
    ) private pure returns (SimpleLensRatioUtils.PositionStats memory stat) {
        stat.tickLower = position.lowerTick;
        stat.tickUpper = position.upperTick;
        stat.sqrtPriceLower = TickMath.getSqrtPriceAtTick(position.lowerTick);
        stat.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(position.upperTick);
        stat.liquidity = liquidity;

        (stat.token0Quantity, stat.token1Quantity) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, stat.sqrtPriceLower, stat.sqrtPriceUpper, liquidity);

        stat.valueInToken1 = stat.token1Quantity
            + FullMath.mulDiv(stat.token0Quantity, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
        stat.isLimit = isLimit;
    }

    function _calculateSwapAndPreviewWithSqrtPrice(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        SimpleLensInMin.InitialDepositWithSwapParams calldata params
    )
        private
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            SimpleLensInMin.RebalancePreview memory preview
        )
    {
        SimpleLensInMin.PreviewContext memory ctx;
        ctx.sqrtPriceX96 = sqrtPriceX96;
        ctx.currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        ctx.resolvedCenter =
            RebalanceLogic.resolveAndClampCenterTick(params.centerTick, ctx.currentTick, poolKey.tickSpacing);

        (swapParams, ctx.finalAmount0, ctx.finalAmount1) =
            _calculateSwapDetails(params, ctx.sqrtPriceX96, ctx.resolvedCenter, poolKey.tickSpacing, ctx.currentTick);

        RebalanceLogic.StrategyContext memory rbCtx = RebalanceLogic.StrategyContext({
            resolvedStrategy: params.strategyAddress,
            center: ctx.resolvedCenter,
            tLeft: params.ticksLeft,
            tRight: params.ticksRight,
            strategy: ILiquidityStrategy(params.strategyAddress),
            weight0: swapParams.weight0,
            weight1: swapParams.weight1,
            useCarpet: params.useCarpet,
            limitWidth: params.limitWidth,
            useAssetWeights: (params.weight0 == 0 && params.weight1 == 0)
        });

        (IMultiPositionManager.Range[] memory ranges, uint128[] memory liquidities) =
            _generateRangesAndLiquiditiesWithSqrtPrice(poolKey, rbCtx, ctx.finalAmount0, ctx.finalAmount1, ctx.sqrtPriceX96);

        {
            SimpleLensInMin.LimitPositionsParams memory limitParams = SimpleLensInMin.LimitPositionsParams({
                limitWidth: params.limitWidth,
                currentTick: ctx.currentTick,
                tickSpacing: poolKey.tickSpacing,
                maxSlippageBps: params.maxSlippageBps,
                sqrtPriceX96: ctx.sqrtPriceX96,
                totalAmount0: ctx.finalAmount0,
                totalAmount1: ctx.finalAmount1
            });
            (ranges, liquidities, inMin) = SimpleLensInMin.addLimitPositionsAndCalculateInMin(ranges, liquidities, limitParams);
        }

        preview = _buildPreviewFromRangesAndLiquidities(ranges, liquidities, params, ctx);

        finalAmount0 = ctx.finalAmount0;
        finalAmount1 = ctx.finalAmount1;

        return (finalAmount0, finalAmount1, swapParams, inMin, preview);
    }

    function _buildPreviewFromRangesAndLiquidities(
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        SimpleLensInMin.InitialDepositWithSwapParams calldata params,
        SimpleLensInMin.PreviewContext memory ctx
    ) private pure returns (SimpleLensInMin.RebalancePreview memory preview) {
        preview.ranges = ranges;
        preview.strategy = params.strategyAddress;
        preview.centerTick = ctx.resolvedCenter;
        preview.ticksLeft = params.ticksLeft;
        preview.ticksRight = params.ticksRight;
        preview.liquidities = liquidities;
        preview.postSwapAmount0 = ctx.finalAmount0;
        preview.postSwapAmount1 = ctx.finalAmount1;

        uint256 baseLength = params.limitWidth > 0 && ranges.length >= 2 ? ranges.length - 2 : ranges.length;
        preview.expectedPositions = new SimpleLensRatioUtils.PositionStats[](ranges.length);
        _populateExpectedPositions(ranges, liquidities, ctx.sqrtPriceX96, preview, baseLength);

        return preview;
    }

    function _calculateSwapDetails(
        SimpleLensInMin.InitialDepositWithSwapParams calldata params,
        uint160 sqrtPriceX96,
        int24 resolvedCenter,
        int24 tickSpacing,
        int24 currentTick
    )
        private
        view
        returns (SimpleLensRatioUtils.SwapParams memory swapParams, uint256 finalAmount0, uint256 finalAmount1)
    {
        if (params.weight0 == 0 && params.weight1 == 0) {
            (swapParams.weight0, swapParams.weight1) = RebalanceLogic.calculateWeightsFromStrategy(
                ILiquidityStrategy(params.strategyAddress),
                resolvedCenter,
                params.ticksLeft,
                params.ticksRight,
                tickSpacing,
                params.useCarpet,
                sqrtPriceX96,
                currentTick
            );
        } else {
            swapParams.weight0 = params.weight0;
            swapParams.weight1 = params.weight1;
        }

        (bool swapToken0, uint256 swapAmount) = RebalanceLogic.calculateOptimalSwap(
            params.amount0, params.amount1, sqrtPriceX96, swapParams.weight0, swapParams.weight1
        );

        swapParams.swapToken0 = swapToken0;
        swapParams.swapAmount = swapAmount;

        finalAmount0 = params.amount0;
        finalAmount1 = params.amount1;

        if (swapAmount > 0) {
            if (swapToken0) {
                uint256 amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(swapAmount, uint256(sqrtPriceX96), 1 << 96), uint256(sqrtPriceX96), 1 << 96
                );
                finalAmount0 -= swapAmount;
                finalAmount1 += amountOut;
            } else {
                uint256 amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(swapAmount, 1 << 96, uint256(sqrtPriceX96)), 1 << 96, uint256(sqrtPriceX96)
                );
                finalAmount1 -= swapAmount;
                finalAmount0 += amountOut;
            }
        }

        return (swapParams, finalAmount0, finalAmount1);
    }

    function _populateExpectedPositions(
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        uint160 sqrtPriceX96,
        SimpleLensInMin.RebalancePreview memory preview,
        uint256 baseLength
    ) private pure {
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96);

        preview.expectedTotal0 = 0;
        preview.expectedTotal1 = 0;

        for (uint256 i = 0; i < ranges.length; i++) {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 amount0, uint256 amount1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidities[i]);

            uint256 valueInToken1 = amount1 + FullMath.mulDiv(amount0, price, 1e18);

            preview.expectedPositions[i] = SimpleLensRatioUtils.PositionStats({
                tickLower: ranges[i].lowerTick,
                tickUpper: ranges[i].upperTick,
                sqrtPriceLower: sqrtPriceLower,
                sqrtPriceUpper: sqrtPriceUpper,
                liquidity: liquidities[i],
                token0Quantity: amount0,
                token1Quantity: amount1,
                valueInToken1: valueInToken1,
                isLimit: i >= baseLength
            });

            preview.expectedTotal0 += amount0;
            preview.expectedTotal1 += amount1;
        }
    }

    function _generateRangesAndLiquiditiesWithSqrtPrice(
        PoolKey memory poolKey,
        RebalanceLogic.StrategyContext memory ctx,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    ) private view returns (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory liquidities) {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        uint256[] memory weights;
        (baseRanges, weights) = _generateRangesAndWeightsWithTick(poolKey, ctx, currentTick, ctx.useCarpet);

        liquidities = new uint128[](baseRanges.length);
        bool useAssetWeights = ctx.useAssetWeights;

        RebalanceLogic.LiquidityCalcParams memory calcParams = RebalanceLogic.LiquidityCalcParams({
            amount0: amount0,
            amount1: amount1,
            sqrtPriceX96: sqrtPriceX96,
            useAssetWeights: useAssetWeights,
            tickSpacing: poolKey.tickSpacing,
            useCarpet: ctx.useCarpet
        });
        RebalanceLogic._calculateLiquiditiesFromWeightsWithParams(liquidities, weights, baseRanges, calcParams);
    }

    function _generateRangesAndWeightsWithTick(
        PoolKey memory poolKey,
        RebalanceLogic.StrategyContext memory ctx,
        int24 currentTick,
        bool useCarpet
    ) private view returns (IMultiPositionManager.Range[] memory baseRanges, uint256[] memory weights) {
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            ctx.strategy.generateRanges(ctx.center, ctx.tLeft, ctx.tRight, poolKey.tickSpacing, useCarpet);

        baseRanges = new IMultiPositionManager.Range[](lowerTicks.length);
        for (uint256 i = 0; i < lowerTicks.length;) {
            baseRanges[i] = IMultiPositionManager.Range(lowerTicks[i], upperTicks[i]);
            unchecked {
                ++i;
            }
        }

        RebalanceLogic.StrategyContext memory weightCtx = ctx;
        weightCtx.useCarpet = useCarpet;
        weights = _calculateWeightsWithTick(poolKey, weightCtx, lowerTicks, upperTicks, currentTick);
    }

    function _calculateWeightsWithTick(
        PoolKey memory poolKey,
        RebalanceLogic.StrategyContext memory ctx,
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        int24 currentTick
    ) private view returns (uint256[] memory) {
        WeightCallParams memory callParams = WeightCallParams({
            strategy: address(ctx.strategy),
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            currentTick: currentTick,
            center: ctx.center,
            tLeft: ctx.tLeft,
            tRight: ctx.tRight,
            weight0: ctx.weight0,
            weight1: ctx.weight1,
            useCarpet: ctx.useCarpet,
            tickSpacing: poolKey.tickSpacing,
            useAssetWeights: ctx.useAssetWeights
        });

        {
            bool supportsWeightedDist = false;
            try ctx.strategy.supportsWeights() returns (bool supported) {
                supportsWeightedDist = supported;
            } catch {}

            if (
                !callParams.useCarpet && !supportsWeightedDist
                    && (callParams.weight0 != 0.5e18 || callParams.weight1 != 0.5e18)
            ) {
                callParams.weight0 = 0.5e18;
                callParams.weight1 = 0.5e18;
            }
        }

        return _executeWeightCall(callParams);
    }

    function _executeWeightCall(WeightCallParams memory callParams) private view returns (uint256[] memory) {
        bytes memory callData = abi.encodeCall(
            ILiquidityStrategy.calculateDensities,
            (
                callParams.lowerTicks,
                callParams.upperTicks,
                callParams.currentTick,
                callParams.center,
                callParams.tLeft,
                callParams.tRight,
                callParams.weight0,
                callParams.weight1,
                callParams.useCarpet,
                callParams.tickSpacing,
                callParams.useAssetWeights
            )
        );

        (bool success, bytes memory returnData) = callParams.strategy.staticcall(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        uint256[] memory weights = abi.decode(returnData, (uint256[]));
        return RebalanceLogic.adjustWeightsForFullRangeFloor(
            weights, callParams.lowerTicks, callParams.upperTicks, callParams.tickSpacing, callParams.useCarpet
        );
    }
}
