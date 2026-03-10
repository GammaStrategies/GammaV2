// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MultiPositionManager} from "../../MultiPositionManager.sol";
import {IMultiPositionManager} from "../../interfaces/IMultiPositionManager.sol";
import {ILiquidityStrategy} from "../../strategies/ILiquidityStrategy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SimpleLensInMin} from "./SimpleLensInMin.sol";
import {SimpleLensRatioUtils} from "./SimpleLensRatioUtils.sol";
import {RebalanceLogic} from "../RebalanceLogic.sol";
import {PositionLogic} from "../PositionLogic.sol";
import {PoolManagerUtils} from "../PoolManagerUtils.sol";
import {LiquidityAmountsCapped} from "../LiquidityAmountsCapped.sol";
import {WithdrawLogic} from "../WithdrawLogic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SimpleLensInMinPreview
 * @notice Preview helpers split from SimpleLensInMin to reduce runtime size.
 */
library SimpleLensInMinPreview {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /**
     * @notice Internal helper for getting outMin for withdrawal
     */
    function _calculateOutMinForShares(MultiPositionManager manager, uint256 shares, uint256 maxSlippage)
        private
        view
        returns (uint256[2][] memory outMin)
    {
        uint256 totalSupply = manager.totalSupply();
        if (totalSupply == 0 || shares == 0) {
            return new uint256[2][](0);
        }

        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        outMin = new uint256[2][](ranges.length);
        uint256 slippageMultiplier = 10000 - maxSlippage;

        for (uint256 i = 0; i < ranges.length; i++) {
            uint256 positionLiquidity = uint256(positionData[i].liquidity);
            if (positionLiquidity == 0) {
                outMin[i] = [uint256(0), uint256(0)];
                continue;
            }

            uint128 liquidityToBurn = uint128(FullMath.mulDiv(positionLiquidity, shares, totalSupply));

            (uint256 amt0, uint256 amt1) = PoolManagerUtils.getAmountsForLiquidity(
                manager.poolManager(), manager.poolKey(), ranges[i], liquidityToBurn
            );

            outMin[i] =
                [FullMath.mulDiv(amt0, slippageMultiplier, 10000), FullMath.mulDiv(amt1, slippageMultiplier, 10000)];
        }
    }

    /**
     * @notice Public wrapper for getting outMin for withdrawal
     */
    function getOutMinForShares(MultiPositionManager manager, uint256 shares, uint256 maxSlippage)
        external
        view
        returns (uint256[2][] memory outMin)
    {
        return _calculateOutMinForShares(manager, shares, maxSlippage);
    }

    function calculateSwapAndPreview(
        IPoolManager poolManager,
        PoolKey memory poolKey,
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
        // 1. Build context
        SimpleLensInMin.PreviewContext memory ctx;
        (ctx.sqrtPriceX96, ctx.currentTick, ctx.resolvedCenter) =
            _getPoolStateAndResolveCenter(poolManager, poolKey, params.centerTick);

        // 2. Calculate swap
        (swapParams, ctx.finalAmount0, ctx.finalAmount1) =
            _calculateSwapDetails(params, ctx.sqrtPriceX96, ctx.resolvedCenter, poolKey.tickSpacing, ctx.currentTick);

        // 3. Use RebalanceLogic to generate ranges and liquidities (same logic as actual deployment!)
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

        // Generate ranges and liquidities using EXACT same function as deployment
        (IMultiPositionManager.Range[] memory ranges, uint128[] memory liquidities) = RebalanceLogic
            .generateRangesAndLiquiditiesWithPoolKey(poolKey, poolManager, rbCtx, ctx.finalAmount0, ctx.finalAmount1);

        // 4. Add limit positions if limitWidth > 0
        if (params.limitWidth > 0) {
            SimpleLensInMin.LimitPositionsParams memory limitParams = SimpleLensInMin.LimitPositionsParams({
                limitWidth: params.limitWidth,
                currentTick: ctx.currentTick,
                tickSpacing: poolKey.tickSpacing,
                maxSlippageBps: params.maxSlippageBps,
                sqrtPriceX96: ctx.sqrtPriceX96,
                totalAmount0: ctx.finalAmount0,
                totalAmount1: ctx.finalAmount1
            });
            (ranges, liquidities,) = _addLimitPositionsAndCalculateInMin(ranges, liquidities, limitParams);
        }

        // 5. Build preview and inMin from the generated ranges/liquidities
        (inMin, preview) =
            _buildPreviewFromRangesAndLiquidities(poolManager, poolKey, ranges, liquidities, params, ctx, swapParams);

        // Return final amounts and swap params
        finalAmount0 = ctx.finalAmount0;
        finalAmount1 = ctx.finalAmount1;

        return (finalAmount0, finalAmount1, swapParams, inMin, preview);
    }

    function simulateRebalance(
        MultiPositionManager manager,
        uint256 totalAmount0,
        uint256 totalAmount1,
        IMultiPositionManager.RebalanceParams memory params
    ) external view returns (SimpleLensInMin.RebalancePreview memory preview) {
        return _simulateRebalance(manager, totalAmount0, totalAmount1, params);
    }

    function _simulateRebalance(
        MultiPositionManager manager,
        uint256 totalAmount0,
        uint256 totalAmount1,
        IMultiPositionManager.RebalanceParams memory params
    ) private view returns (SimpleLensInMin.RebalancePreview memory preview) {
        IPoolManager poolManager = manager.poolManager();
        PoolKey memory poolKey = manager.poolKey();

        // Get pool state and resolve center
        SimpleLensInMin.PreviewContext memory ctx;
        (ctx.sqrtPriceX96, ctx.currentTick, ctx.resolvedCenter) =
            _getPoolStateAndResolveCenter(poolManager, poolKey, params.center);

        // Calculate swap (assuming no swap for simplicity, weight0/weight1 passed through)
        SimpleLensRatioUtils.SwapParams memory swapParams;
        swapParams.weight0 = params.weight0;
        swapParams.weight1 = params.weight1;
        ctx.finalAmount0 = totalAmount0;
        ctx.finalAmount1 = totalAmount1;

        // Use RebalanceLogic to generate ranges and liquidities
        RebalanceLogic.StrategyContext memory rbCtx = RebalanceLogic.StrategyContext({
            resolvedStrategy: params.strategy,
            center: ctx.resolvedCenter,
            tLeft: params.tLeft,
            tRight: params.tRight,
            strategy: ILiquidityStrategy(params.strategy),
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            limitWidth: params.limitWidth,
            useAssetWeights: (params.weight0 == 0 && params.weight1 == 0)
        });

        (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory baseLiquidities) = RebalanceLogic
            .generateRangesAndLiquiditiesWithPoolKey(poolKey, poolManager, rbCtx, ctx.finalAmount0, ctx.finalAmount1);

        // Add limit positions
        IMultiPositionManager.Range[] memory allRanges;
        uint128[] memory allLiquidities;

        if (params.limitWidth > 0) {
            (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit) =
                PositionLogic.calculateLimitRanges(params.limitWidth, baseRanges, poolKey.tickSpacing, ctx.currentTick);

            allRanges = new IMultiPositionManager.Range[](baseRanges.length + 2);
            allLiquidities = new uint128[](baseRanges.length + 2);

            for (uint256 i = 0; i < baseRanges.length; i++) {
                allRanges[i] = baseRanges[i];
                allLiquidities[i] = baseLiquidities[i];
            }

            (uint256 remainderToken0, uint256 remainderToken1) =
                _calculateRemainders(baseRanges, baseLiquidities, ctx.sqrtPriceX96, ctx.finalAmount0, ctx.finalAmount1);

            allRanges[baseRanges.length] = lowerLimit;
            allRanges[baseRanges.length + 1] = upperLimit;

            if (lowerLimit.lowerTick != lowerLimit.upperTick && remainderToken1 > 0) {
                allLiquidities[baseRanges.length] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    ctx.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(lowerLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(lowerLimit.upperTick),
                    0,
                    remainderToken1
                );
            } else {
                allLiquidities[baseRanges.length] = 0;
            }

            if (upperLimit.lowerTick != upperLimit.upperTick && remainderToken0 > 0) {
                allLiquidities[baseRanges.length + 1] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    ctx.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(upperLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(upperLimit.upperTick),
                    remainderToken0,
                    0
                );
            } else {
                allLiquidities[baseRanges.length + 1] = 0;
            }
        } else {
            allRanges = baseRanges;
            allLiquidities = baseLiquidities;
        }

        preview.ranges = allRanges;
        preview.strategy = params.strategy;
        preview.centerTick = ctx.resolvedCenter;
        preview.ticksLeft = params.tLeft;
        preview.ticksRight = params.tRight;
        preview.liquidities = allLiquidities;
        preview.postSwapAmount0 = ctx.finalAmount0;
        preview.postSwapAmount1 = ctx.finalAmount1;

        preview.expectedPositions = new SimpleLensRatioUtils.PositionStats[](allRanges.length);
        _populateExpectedPositions(allRanges, allLiquidities, ctx.sqrtPriceX96, preview, baseRanges.length);
    }

    function previewWithdrawCustomInternal(
        MultiPositionManager manager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) external view returns (SimpleLensInMin.WithdrawPreviewResult memory result) {
        SimpleLensInMin.PreviewData memory data;

        (data.total0, data.total1, data.totalFee0, data.totalFee1) = manager.getTotalAmounts();
        data.totalSupply = manager.totalSupply();
        data.totalPositions = manager.basePositionsLength() + manager.limitPositionsLength();

        result.sharesWithdrawn = WithdrawLogic.calculateSharesToBurnForManager(
            address(manager), amount0Desired, amount1Desired, data.totalSupply, data.total0, data.total1
        );

        (data.unusedAmount0, data.unusedAmount1) = _getUnusedBalances(manager, manager.poolKey());

        if (
            (data.unusedAmount0 + data.totalFee0) >= amount0Desired
                && (data.unusedAmount1 + data.totalFee1) >= amount1Desired
        ) {
            _handlePath1And2(result, manager, data, amount0Desired, amount1Desired, previewRebalance, rebalanceParams);
        } else {
            _handlePath3WithRebalance(
                result, manager, data, amount0Desired, amount1Desired, maxSlippage, previewRebalance, rebalanceParams
            );
        }
    }

    function addLimitPositionsAndCalculateInMin(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        SimpleLensInMin.LimitPositionsParams memory params
    )
        external
        pure
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        return _addLimitPositionsAndCalculateInMin(baseRanges, baseLiquidities, params);
    }

    function _buildPreviewFromRangesAndLiquidities(
        IPoolManager /* poolManager */,
        PoolKey memory /* poolKey */,
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        SimpleLensInMin.InitialDepositWithSwapParams calldata params,
        SimpleLensInMin.PreviewContext memory ctx,
        SimpleLensRatioUtils.SwapParams memory /* swapParams */
    ) private pure returns (uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview) {
        // Calculate inMin from liquidities
        inMin = new uint256[2][](ranges.length);
        uint256 slippageMultiplier = 10000 - params.maxSlippageBps;

        for (uint256 i = 0; i < ranges.length; i++) {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                ctx.sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidities[i]
            );

            inMin[i] = [
                FullMath.mulDiv(amount0, slippageMultiplier, 10000),
                FullMath.mulDiv(amount1, slippageMultiplier, 10000)
            ];
        }

        // Build preview
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
        return (inMin, preview);
    }

    function _getPoolStateAndResolveCenter(IPoolManager poolManager, PoolKey memory poolKey, int24 centerTick)
        private
        view
        returns (uint160 sqrtPriceX96, int24 currentTick, int24 resolvedCenter)
    {
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());

        resolvedCenter = RebalanceLogic.resolveAndClampCenterTick(centerTick, currentTick, poolKey.tickSpacing);

        return (sqrtPriceX96, currentTick, resolvedCenter);
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

    function _getUnusedBalances(MultiPositionManager manager, PoolKey memory poolKey)
        private
        view
        returns (uint256 unusedAmount0, uint256 unusedAmount1)
    {
        address managerAddr = address(manager);
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        address addr0 = Currency.unwrap(currency0);
        address addr1 = Currency.unwrap(currency1);

        unusedAmount0 = addr0 == address(0) ? managerAddr.balance : IERC20(addr0).balanceOf(managerAddr);
        unusedAmount1 = addr1 == address(0) ? managerAddr.balance : IERC20(addr1).balanceOf(managerAddr);
    }

    function _handlePath1And2(
        SimpleLensInMin.WithdrawPreviewResult memory result,
        MultiPositionManager manager,
        SimpleLensInMin.PreviewData memory data,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) private view {
        result.positionSharesBurned = 0;
        result.isFullBurn = false;

        (result.outMin, result.outMinForRebalance) = _createZeroOutMinArrays(data.totalPositions);

        if (previewRebalance && rebalanceParams.strategy != address(0)) {
            uint256 r0 = (data.unusedAmount0 + data.totalFee0) - amount0Desired;
            uint256 r1 = (data.unusedAmount1 + data.totalFee1) - amount1Desired;
            result.rebalancePreview = _simulateRebalance(manager, r0, r1, rebalanceParams);
        }
    }

    function _handlePath3WithRebalance(
        SimpleLensInMin.WithdrawPreviewResult memory result,
        MultiPositionManager manager,
        SimpleLensInMin.PreviewData memory data,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) private view {
        result.positionSharesBurned =
            WithdrawLogic.calculatePositionSharesToBurnForSimpleLens(address(manager), amount0Desired, amount1Desired);

        result.outMin = SimpleLensInMin.getOutMinForShares(manager, result.positionSharesBurned, maxSlippage);

        result.isFullBurn = (result.positionSharesBurned == data.totalSupply);

        result.outMinForRebalance = _createOutMinForRebalanceArray(result.isFullBurn, data.totalPositions);

        if (previewRebalance && rebalanceParams.strategy != address(0)) {
            uint256 r0 = data.total0 - amount0Desired;
            uint256 r1 = data.total1 - amount1Desired;

            result.rebalancePreview = _simulateRebalance(manager, r0, r1, rebalanceParams);
        }
    }

    function _createZeroOutMinArrays(uint256 totalPositions)
        private
        pure
        returns (uint256[2][] memory outMin, uint256[2][] memory outMinForRebalance)
    {
        outMin = new uint256[2][](totalPositions);
        outMinForRebalance = new uint256[2][](totalPositions);
        for (uint256 i = 0; i < totalPositions; i++) {
            outMin[i] = [uint256(0), uint256(0)];
            outMinForRebalance[i] = [uint256(0), uint256(0)];
        }
    }

    function _createOutMinForRebalanceArray(bool isFullBurn, uint256 totalPositions)
        private
        pure
        returns (uint256[2][] memory outMinForRebalance)
    {
        if (isFullBurn) {
            return new uint256[2][](0);
        }

        outMinForRebalance = new uint256[2][](totalPositions);
        for (uint256 i = 0; i < totalPositions; i++) {
            outMinForRebalance[i] = [uint256(0), uint256(0)];
        }
    }

    function _addLimitPositionsAndCalculateInMin(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        SimpleLensInMin.LimitPositionsParams memory params
    )
        private
        pure
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        if (params.limitWidth > 0) {
            IMultiPositionManager.Range memory lowerLimit;
            IMultiPositionManager.Range memory upperLimit;

            {
                (lowerLimit, upperLimit) = PositionLogic.calculateLimitRanges(
                    params.limitWidth, baseRanges, params.tickSpacing, params.currentTick
                );
            }

            allRanges = new IMultiPositionManager.Range[](baseRanges.length + 2);
            allLiquidities = new uint128[](baseRanges.length + 2);

            for (uint256 i = 0; i < baseRanges.length; i++) {
                allRanges[i] = baseRanges[i];
                allLiquidities[i] = baseLiquidities[i];
            }

            (uint256 remainderToken0, uint256 remainderToken1) = _calculateRemainders(
                baseRanges, baseLiquidities, params.sqrtPriceX96, params.totalAmount0, params.totalAmount1
            );

            allRanges[baseRanges.length] = lowerLimit;
            allRanges[baseRanges.length + 1] = upperLimit;

            if (lowerLimit.lowerTick != lowerLimit.upperTick && remainderToken1 > 0) {
                allLiquidities[baseRanges.length] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    params.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(lowerLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(lowerLimit.upperTick),
                    0,
                    remainderToken1
                );
            } else {
                allLiquidities[baseRanges.length] = 0;
            }

            if (upperLimit.lowerTick != upperLimit.upperTick && remainderToken0 > 0) {
                allLiquidities[baseRanges.length + 1] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    params.sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(upperLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(upperLimit.upperTick),
                    remainderToken0,
                    0
                );
            } else {
                allLiquidities[baseRanges.length + 1] = 0;
            }
        } else {
            allRanges = baseRanges;
            allLiquidities = baseLiquidities;
        }

        inMin = _calculateInMin(baseRanges, baseLiquidities, params.maxSlippageBps, params.sqrtPriceX96);
    }

    function _calculateRemainders(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        uint160 sqrtPriceX96,
        uint256 totalAmount0,
        uint256 totalAmount1
    ) private pure returns (uint256 remainderToken0, uint256 remainderToken1) {
        uint256 consumedToken0;
        uint256 consumedToken1;
        for (uint256 i = 0; i < baseRanges.length; i++) {
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(baseRanges[i].lowerTick),
                TickMath.getSqrtPriceAtTick(baseRanges[i].upperTick),
                baseLiquidities[i]
            );
            consumedToken0 += amt0;
            consumedToken1 += amt1;
        }
        remainderToken0 = totalAmount0 > consumedToken0 ? totalAmount0 - consumedToken0 : 0;
        remainderToken1 = totalAmount1 > consumedToken1 ? totalAmount1 - consumedToken1 : 0;
    }

    function _calculateInMin(
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        uint256 maxSlippageBps,
        uint160 sqrtPriceX96
    ) private pure returns (uint256[2][] memory inMin) {
        inMin = new uint256[2][](ranges.length);
        uint256 slippageMultiplier = 10000 - maxSlippageBps;

        for (uint256 i = 0; i < ranges.length; i++) {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidities[i]
            );

            inMin[i] = [
                FullMath.mulDiv(amt0, slippageMultiplier, 10000),
                FullMath.mulDiv(amt1, slippageMultiplier, 10000)
            ];
        }
    }

    function calculateOtherAmountInline(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        SimpleLensInMin.CalculateOtherAmountParams memory params
    ) external view returns (uint256 otherAmount) {
        uint160 sqrtPriceX96 = params.sqrtPriceX96;
        if (sqrtPriceX96 == 0) {
            (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        }

        (int24[] memory lowerTicks, int24[] memory upperTicks, uint256[] memory weights) =
            _generateRangesAndWeights(poolKey, params, sqrtPriceX96);

        (uint256 totalWeightedToken0, uint256 totalWeightedToken1) =
            _calculateWeightedTotals(lowerTicks, upperTicks, weights, sqrtPriceX96);

        if (params.isToken0) {
            otherAmount =
                totalWeightedToken0 == 0 ? 0 : FullMath.mulDiv(params.amount, totalWeightedToken1, totalWeightedToken0);
        } else {
            otherAmount =
                totalWeightedToken1 == 0 ? 0 : FullMath.mulDiv(params.amount, totalWeightedToken0, totalWeightedToken1);
        }
    }

    struct DensityCallParams {
        ILiquidityStrategy strategy;
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

    function _generateRangesAndWeights(
        PoolKey memory poolKey,
        SimpleLensInMin.CalculateOtherAmountParams memory params,
        uint160 sqrtPriceX96
    ) private view returns (int24[] memory lowerTicks, int24[] memory upperTicks, uint256[] memory weights) {
        ILiquidityStrategy strategy = ILiquidityStrategy(params.strategyAddress);

        (lowerTicks, upperTicks) = strategy.generateRanges(
            params.resolvedCenterTick, params.ticksLeft, params.ticksRight, poolKey.tickSpacing, params.useCarpet
        );

        bool useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);
        uint256 weight0 = params.weight0;
        uint256 weight1 = params.weight1;

        if (!params.useCarpet) {
            bool supportsWeightedDist = false;
            try strategy.supportsWeights() returns (bool supported) {
                supportsWeightedDist = supported;
            } catch {}

            if (!supportsWeightedDist && (weight0 != 0.5e18 || weight1 != 0.5e18)) {
                weight0 = 0.5e18;
                weight1 = 0.5e18;
            }
        }

        DensityCallParams memory callParams = DensityCallParams({
            strategy: strategy,
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            currentTick: TickMath.getTickAtSqrtPrice(sqrtPriceX96),
            center: params.resolvedCenterTick,
            tLeft: params.ticksLeft,
            tRight: params.ticksRight,
            weight0: weight0,
            weight1: weight1,
            useCarpet: params.useCarpet,
            tickSpacing: poolKey.tickSpacing,
            useAssetWeights: useAssetWeights
        });

        weights = _calculateDensities(callParams);

        weights = RebalanceLogic.adjustWeightsForFullRangeFloor(
            weights, lowerTicks, upperTicks, poolKey.tickSpacing, params.useCarpet
        );
    }

    function _calculateDensities(DensityCallParams memory callParams) private view returns (uint256[] memory) {
        return callParams.strategy.calculateDensities(
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
        );
    }

    function _calculateWeightedTotals(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        uint256[] memory weights,
        uint160 sqrtPriceX96
    ) private pure returns (uint256 totalWeightedToken0, uint256 totalWeightedToken1) {
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(lowerTicks[i]),
                TickMath.getSqrtPriceAtTick(upperTicks[i]),
                1e18
            );
            totalWeightedToken0 += FullMath.mulDiv(amt0, weights[i], 1e18);
            totalWeightedToken1 += FullMath.mulDiv(amt1, weights[i], 1e18);
        }
    }
}
