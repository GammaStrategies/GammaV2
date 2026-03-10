// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MultiPositionManager} from "../MultiPositionManager.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {ILiquidityStrategy} from "../strategies/ILiquidityStrategy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {DepositRatioLib} from "../libraries/DepositRatioLib.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManagerUtils} from "../libraries/PoolManagerUtils.sol";
import {RebalanceLogic} from "../libraries/RebalanceLogic.sol";
import {PositionLogic} from "../libraries/PositionLogic.sol";
import {WithdrawLogic} from "../libraries/WithdrawLogic.sol";
import {LiquidityAmountsCapped} from "../libraries/LiquidityAmountsCapped.sol";
import {SimpleLensInMin} from "../libraries/SimpleLens/SimpleLensInMin.sol";
import {SimpleLensInMinPreview} from "../libraries/SimpleLens/SimpleLensInMinPreview.sol";
import {SimpleLensRatioUtils} from "../libraries/SimpleLens/SimpleLensRatioUtils.sol";
import {SimpleLensLibrary} from "../libraries/SimpleLens/SimpleLensLibrary.sol";

/**
 * @title SimpleLens
 * @notice Simplified read-only contract for previewing MultiPositionManager withdrawals
 */
contract SimpleLens {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Immutable storage
    IPoolManager public immutable poolManager;

    // Custom errors
    error NoStrategySpecified();
    error MaxSlippageExceeded();
    error RatioMustBeLessThanOrEqualToOne();
    error InvalidRatioForDeposit();
    error GenerateRangesFailed();
    error CalculateDensitiesFailed();

    uint256 constant PRECISION = 1e18;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // Use structs from SimpleLensInMin library to avoid duplication
    // DensityCalcParams, InMinCalcData, and InMinRebalanceParams are now in SimpleLensInMin

    struct DensityCalcContext {
        int24[] lowerTicks;
        int24[] upperTicks;
        int24 currentTick;
        int24 resolvedCenterTick;
        int24 tickSpacing;
    }

    struct PriceData {
        uint160 sqrtPriceX96;
        uint256 price;
        int24 tick;
    }

    // PreviewData and WithdrawPreviewResult structs moved to SimpleLensInMin library

    struct Path3Params {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 sharesWithdrawn;
        uint256[2][] outMin;
        bool previewRebalance;
        IMultiPositionManager.RebalanceParams rebalanceParams;
    }

    // RebalancePreview struct moved to SimpleLensInMin library

    struct InMinParams {
        MultiPositionManager manager;
        IMultiPositionManager.Range[] baseRanges;
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        uint256 maxSlippage;
    }

    struct PreviewLiquidityParams {
        IMultiPositionManager.Range[] baseRanges;
        uint256 total0;
        uint256 total1;
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
    }

    struct PreviewRebalanceParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        uint256 maxSlippageOutMin;
        uint256 maxSlippageInMin;
    }

    /**
     * @notice Get position statistics for a MultiPositionManager
     */
    function getPositionStats(MultiPositionManager manager)
        external
        view
        returns (SimpleLensRatioUtils.PositionStats[] memory stats)
    {
        return SimpleLensRatioUtils.getPositionStats(manager);
    }

    /**
     * @notice Preview a custom withdrawal using WithdrawLogic paths
     * @param manager The MultiPositionManager contract
     * @param amount0Desired Amount of token0 to withdraw
     * @param amount1Desired Amount of token1 to withdraw
     * @param maxSlippage Maximum slippage for outMin calculation
     * @param previewRebalance If true, returns expected positions after rebalance
     * @param rebalanceParams Parameters for rebalance preview
     * @return sharesWithdrawn Amount of shares withdrawn
     * @return positionSharesBurned Amount of position shares burned
     * @return outMin Minimum output amounts for withdrawal
     * @return rebalancePreview Full rebalance preview (empty if previewRebalance false)
     * @return isFullBurn True if all positions will be burned (positionSharesBurned == totalSupply)
     * @return outMinForRebalance Empty array if full burn, otherwise [0,0] array sized for remaining positions
     */
    function previewWithdrawCustom(
        MultiPositionManager manager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    )
        external
        view
        returns (
            uint256 sharesWithdrawn,
            uint256 positionSharesBurned,
            uint256[2][] memory outMin,
            SimpleLensInMin.RebalancePreview memory rebalancePreview,
            bool isFullBurn,
            uint256[2][] memory outMinForRebalance
        )
    {
        // Call library function for all preview logic
        SimpleLensInMin.WithdrawPreviewResult memory result = SimpleLensInMinPreview.previewWithdrawCustomInternal(
            manager, amount0Desired, amount1Desired, maxSlippage, previewRebalance, rebalanceParams
        );

        return (
            result.sharesWithdrawn,
            result.positionSharesBurned,
            result.outMin,
            result.rebalancePreview,
            result.isFullBurn,
            result.outMinForRebalance
        );
    }

    function _calculatePositionStats(
        IMultiPositionManager.Position memory position,
        uint128 liquidity,
        uint160 sqrtPriceX96,
        bool isLimit
    ) internal pure returns (SimpleLensRatioUtils.PositionStats memory stat) {
        stat.tickLower = position.lowerTick;
        stat.tickUpper = position.upperTick;
        stat.sqrtPriceLower = TickMath.getSqrtPriceAtTick(position.lowerTick);
        stat.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(position.upperTick);
        stat.liquidity = liquidity;

        (stat.token0Quantity, stat.token1Quantity) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, stat.sqrtPriceLower, stat.sqrtPriceUpper, liquidity);

        // Calculate value in token1
        stat.valueInToken1 = stat.token1Quantity
            + FullMath.mulDiv(stat.token0Quantity, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
        stat.isLimit = isLimit;
    }

    // Consolidated pool state helpers - reduces redundant code
    function _getPoolState(PoolKey memory poolKey) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    /**
     * @notice Preview the result of rebalanceWithStrategy with limitWidth and full-range floor
     * @param manager The MultiPositionManager contract
     * @param params Preview parameters including strategy, ticks, weights, and slippage bounds
     * @return preview Detailed preview of the rebalance operation
     * @return outMin Minimum amounts for withdrawing from old positions
     * @return inMin Minimum amounts for depositing to new positions
     */
    function previewRebalanceWithStrategyAndCarpet(
        MultiPositionManager manager,
        PreviewRebalanceParams calldata params
    )
        public
        view
        returns (SimpleLensInMin.RebalancePreview memory preview, uint256[2][] memory outMin, uint256[2][] memory inMin)
    {
        SimpleLensInMin.RebalancePreviewParams memory internalParams = SimpleLensInMin.RebalancePreviewParams({
            strategyAddress: params.strategyAddress,
            centerTick: params.centerTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false // No swap for regular rebalance
        });

        // Generate preview in helper to reduce stack depth
        preview = _generateCompletePreview(manager, internalParams);

        // Get outMin and inMin for slippage protection
        (outMin, inMin) = _getOutAndInMinForPreview(manager, internalParams, params.maxSlippageOutMin, params.maxSlippageInMin);
    }

    /**
     * @notice Preview the result of rebalanceSwap (with swap) with limitWidth and full-range floor
     * @param manager The MultiPositionManager contract
     * @param params Preview parameters including strategy, ticks, weights, and slippage bounds
     * @return preview Detailed preview of the rebalance operation including swap
     * @return outMin Minimum amounts for withdrawing from old positions
     * @return inMin Minimum amounts for depositing to new positions
     * @return swapParams Swap parameters (direction, amount, target weights)
     */
    function previewRebalanceSwapWithStrategyAndCarpet(
        MultiPositionManager manager,
        PreviewRebalanceParams calldata params
    )
        public
        view
        returns (
            SimpleLensInMin.RebalancePreview memory preview,
            uint256[2][] memory outMin,
            uint256[2][] memory inMin,
            SimpleLensRatioUtils.SwapParams memory swapParams
        )
    {
        SimpleLensInMin.RebalancePreviewParams memory internalParams = SimpleLensInMin.RebalancePreviewParams({
            strategyAddress: params.strategyAddress,
            centerTick: params.centerTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: true // Always swap for this function
        });

        // Generate preview with swap in helper to reduce stack depth
        preview = _generateCompleteSwapPreview(manager, internalParams);

        // Get outMin and inMin for slippage protection
        (outMin, inMin) = _getOutAndInMinForPreview(manager, internalParams, params.maxSlippageOutMin, params.maxSlippageInMin);

        // Construct swap parameters from preview
        swapParams = SimpleLensRatioUtils.SwapParams({
            swapToken0: preview.swapToken0,
            swapAmount: preview.swapAmount,
            weight0: params.weight0,
            weight1: params.weight1
        });
    }

    function _generateCompleteSwapPreview(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params
    ) private view returns (SimpleLensInMin.RebalancePreview memory preview) {
        preview.strategy = params.strategyAddress;
        preview.ticksLeft = params.ticksLeft;
        preview.ticksRight = params.ticksRight;

        // Generate base liquidities with swap simulation
        (uint256 adj0, uint256 adj1) = _generateSwapBaseLiquidities(manager, params, preview);

        // Add limit positions if needed
        if (params.limitWidth > 0) {
            _addSwapLimitPositions(manager, params, adj0, adj1, preview);
        }

        // Calculate expected totals
        _calculateExpectedTotals(manager, preview, params.limitWidth);
    }

    function _generateSwapBaseLiquidities(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params,
        SimpleLensInMin.RebalancePreview memory preview
    ) private view returns (uint256 adjustedTotal0, uint256 adjustedTotal1) {
        PoolKey memory poolKey = manager.poolKey();
        int24 resolvedCenterTick;
        uint256 targetWeight0;
        uint256 targetWeight1;

        // Scope: Calculate weights
        {
            (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

            // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
            resolvedCenterTick =
                RebalanceLogic.resolveAndClampCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);
            preview.centerTick = resolvedCenterTick;

            // Calculate target weights (proportional from strategy if both are 0)
            targetWeight0 = params.weight0;
            targetWeight1 = params.weight1;
            if (params.weight0 == 0 && params.weight1 == 0) {
                (targetWeight0, targetWeight1) = RebalanceLogic.calculateWeightsFromStrategy(
                    ILiquidityStrategy(params.strategyAddress),
                    resolvedCenterTick,
                    params.ticksLeft,
                    params.ticksRight,
                    poolKey.tickSpacing,
                    params.useCarpet,
                    sqrtPriceX96,
                    currentTick
                );
            }
        }

        // Scope: Simulate swap
        {
            uint256 t0;
            uint256 t1;
            (t0, t1,,) = manager.getTotalAmounts();

            (adjustedTotal0, adjustedTotal1) =
                SimpleLensRatioUtils.simulateSwapForRebalance(manager, t0, t1, targetWeight0, targetWeight1);

            // Calculate swap details
            if (adjustedTotal0 < t0) {
                // Swapping token0 for token1
                preview.swapToken0 = true;
                preview.swapAmount = t0 - adjustedTotal0;
                preview.expectedAmountOut = adjustedTotal1 - t1;
            } else if (adjustedTotal1 < t1) {
                // Swapping token1 for token0
                preview.swapToken0 = false;
                preview.swapAmount = t1 - adjustedTotal1;
                preview.expectedAmountOut = adjustedTotal0 - t0;
            } else {
                // No swap needed
                preview.swapToken0 = false;
                preview.swapAmount = 0;
                preview.expectedAmountOut = 0;
            }
        }

        // Build context and generate ranges/liquidities
        RebalanceLogic.StrategyContext memory ctx;
        ctx.resolvedStrategy = params.strategyAddress;
        ctx.center = resolvedCenterTick;
        ctx.tLeft = params.ticksLeft;
        ctx.tRight = params.ticksRight;
        ctx.strategy = ILiquidityStrategy(params.strategyAddress);
        ctx.weight0 = targetWeight0;
        ctx.weight1 = targetWeight1;
        ctx.useCarpet = params.useCarpet;
        ctx.limitWidth = 0;
        ctx.useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);

        // Use same function as actual rebalance
        (preview.ranges, preview.liquidities) = RebalanceLogic.generateRangesAndLiquiditiesWithPoolKey(
            poolKey, poolManager, ctx, adjustedTotal0, adjustedTotal1
        );
    }

    function _getOutAndInMinForPreview(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params,
        uint256 maxSlippageOutMin,
        uint256 maxSlippageInMin
    ) private view returns (uint256[2][] memory outMin, uint256[2][] memory inMin) {
        SimpleLensInMin.RebalanceMinParams memory minParams = SimpleLensInMin.RebalanceMinParams({
            manager: manager,
            strategyAddress: params.strategyAddress,
            centerTick: params.centerTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: params.swap,
            maxSlippageOutMin: maxSlippageOutMin,
            maxSlippageInMin: maxSlippageInMin,
            deductFees: false // deductFees: false for non-relayer context
        });
        return SimpleLensInMin.getOutMinAndInMinForRebalance(minParams);
    }

    function _generateCompletePreview(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params
    ) private view returns (SimpleLensInMin.RebalancePreview memory preview) {
        preview.strategy = params.strategyAddress;
        preview.ticksLeft = params.ticksLeft;
        preview.ticksRight = params.ticksRight;

        // Generate base ranges and liquidities
        uint256 total0;
        uint256 total1;
        (total0, total1) = _generateBasePreviewRanges(manager, params, preview);

        // Add limit positions if limitWidth > 0
        if (params.limitWidth > 0) {
            _addPreviewLimitPositions(manager, params, total0, total1, preview);
        }

        // Calculate expected totals
        _calculateExpectedTotals(manager, preview, params.limitWidth);
    }

    function _generateBasePreviewRanges(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params,
        SimpleLensInMin.RebalancePreview memory preview
    ) private view returns (uint256 total0, uint256 total1) {
        (total0, total1,,) = manager.getTotalAmounts();

        PoolKey memory poolKey = manager.poolKey();
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
        int24 resolvedCenterTick =
            RebalanceLogic.resolveAndClampCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);
        preview.centerTick = resolvedCenterTick;

        // Build context and generate ranges/liquidities
        RebalanceLogic.StrategyContext memory ctx;
        ctx.resolvedStrategy = params.strategyAddress;
        ctx.center = resolvedCenterTick;
        ctx.tLeft = params.ticksLeft;
        ctx.tRight = params.ticksRight;
        ctx.strategy = ILiquidityStrategy(params.strategyAddress);
        ctx.weight0 = params.weight0;
        ctx.weight1 = params.weight1;
        ctx.useCarpet = params.useCarpet;
        ctx.limitWidth = 0;
        ctx.useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);

        (preview.ranges, preview.liquidities) =
            RebalanceLogic.generateRangesAndLiquiditiesWithPoolKey(poolKey, poolManager, ctx, total0, total1);
    }

    function _addPreviewLimitPositions(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params,
        uint256 total0,
        uint256 total1,
        SimpleLensInMin.RebalancePreview memory preview
    ) private view {
        bool useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);
        PoolKey memory poolKey = manager.poolKey();

        // Get limit ranges and sqrtPrice
        IMultiPositionManager.Range memory lowerLimit;
        IMultiPositionManager.Range memory upperLimit;
        uint160 sqrtPriceX96;
        {
            int24 currentTick;
            (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());
            (lowerLimit, upperLimit) =
                PositionLogic.calculateLimitRanges(params.limitWidth, preview.ranges, poolKey.tickSpacing, currentTick);
        }

        // Expand arrays
        uint256 baseLength = preview.ranges.length;
        IMultiPositionManager.Range[] memory allRanges = new IMultiPositionManager.Range[](baseLength + 2);
        uint128[] memory allLiquidities = new uint128[](baseLength + 2);

        // Copy base data
        for (uint256 i = 0; i < baseLength; i++) {
            allRanges[i] = preview.ranges[i];
            allLiquidities[i] = preview.liquidities[i];
        }

        allRanges[baseLength] = lowerLimit;
        allRanges[baseLength + 1] = upperLimit;

        // Calculate limit liquidities for explicit weights
        if (!useAssetWeights) {
            (uint256 consumed0, uint256 consumed1) =
                _calculateConsumedTokens(preview.ranges, preview.liquidities, sqrtPriceX96);

            uint256 remainder0 = total0 > consumed0 ? total0 - consumed0 : 0;
            uint256 remainder1 = total1 > consumed1 ? total1 - consumed1 : 0;

            if (lowerLimit.lowerTick != lowerLimit.upperTick && remainder1 > 0) {
                allLiquidities[baseLength] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(lowerLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(lowerLimit.upperTick),
                    0,
                    remainder1
                );
            }

            if (upperLimit.lowerTick != upperLimit.upperTick && remainder0 > 0) {
                allLiquidities[baseLength + 1] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(upperLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(upperLimit.upperTick),
                    remainder0,
                    0
                );
            }
        }

        preview.ranges = allRanges;
        preview.liquidities = allLiquidities;
    }

    function _addSwapLimitPositions(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreviewParams memory params,
        uint256 adjustedTotal0,
        uint256 adjustedTotal1,
        SimpleLensInMin.RebalancePreview memory preview
    ) private view {
        bool useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);
        PoolKey memory poolKey = manager.poolKey();

        // Get limit ranges and sqrtPrice
        IMultiPositionManager.Range memory lowerLimit;
        IMultiPositionManager.Range memory upperLimit;
        uint160 sqrtPriceX96;
        {
            int24 currentTick;
            (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());
            (lowerLimit, upperLimit) =
                PositionLogic.calculateLimitRanges(params.limitWidth, preview.ranges, poolKey.tickSpacing, currentTick);
        }

        // Expand arrays
        uint256 baseLength = preview.ranges.length;
        IMultiPositionManager.Range[] memory allRanges = new IMultiPositionManager.Range[](baseLength + 2);
        uint128[] memory allLiquidities = new uint128[](baseLength + 2);

        // Copy base data
        for (uint256 i = 0; i < baseLength; i++) {
            allRanges[i] = preview.ranges[i];
            allLiquidities[i] = preview.liquidities[i];
        }

        allRanges[baseLength] = lowerLimit;
        allRanges[baseLength + 1] = upperLimit;

        // Calculate limit liquidities for explicit weights
        if (!useAssetWeights) {
            (uint256 consumed0, uint256 consumed1) =
                _calculateConsumedTokens(preview.ranges, preview.liquidities, sqrtPriceX96);

            uint256 remainder0 = adjustedTotal0 > consumed0 ? adjustedTotal0 - consumed0 : 0;
            uint256 remainder1 = adjustedTotal1 > consumed1 ? adjustedTotal1 - consumed1 : 0;

            if (lowerLimit.lowerTick != lowerLimit.upperTick && remainder1 > 0) {
                allLiquidities[baseLength] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(lowerLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(lowerLimit.upperTick),
                    0,
                    remainder1
                );
            }

            if (upperLimit.lowerTick != upperLimit.upperTick && remainder0 > 0) {
                allLiquidities[baseLength + 1] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(upperLimit.lowerTick),
                    TickMath.getSqrtPriceAtTick(upperLimit.upperTick),
                    remainder0,
                    0
                );
            }
        }

        preview.ranges = allRanges;
        preview.liquidities = allLiquidities;
    }

    function _calculateExpectedTotals(
        MultiPositionManager manager,
        SimpleLensInMin.RebalancePreview memory preview,
        uint24 limitWidth
    ) private view {
        // Create stats for ALL positions (base + limit)
        preview.expectedPositions = new SimpleLensRatioUtils.PositionStats[](preview.ranges.length);
        preview.expectedTotal0 = 0;
        preview.expectedTotal1 = 0;

        PoolKey memory poolKey = manager.poolKey();
        (uint160 sqrtPriceX96,) = _getPoolState(poolKey);

        // Calculate base length: if limitWidth > 0, last 2 positions are limits
        uint256 baseLength =
            limitWidth > 0 && preview.ranges.length >= 2 ? preview.ranges.length - 2 : preview.ranges.length;

        // Calculate stats for all positions including limit positions
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            IMultiPositionManager.Position memory pos = IMultiPositionManager.Position({
                poolKey: poolKey,
                lowerTick: preview.ranges[i].lowerTick,
                upperTick: preview.ranges[i].upperTick
            });

            preview.expectedPositions[i] = _calculatePositionStats(pos, preview.liquidities[i], sqrtPriceX96, i >= baseLength);

            preview.expectedTotal0 += preview.expectedPositions[i].token0Quantity;
            preview.expectedTotal1 += preview.expectedPositions[i].token1Quantity;
        }
    }

    function _generateRangesFromStrategyWithPoolKey(
        PoolKey memory poolKey,
        address strategyAddress,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        bool useCarpet
    ) private view returns (IMultiPositionManager.Range[] memory) {
        return SimpleLensRatioUtils.generateRangesFromStrategyWithPoolKey(
            poolManager, poolKey, strategyAddress, centerTick, ticksLeft, ticksRight, useCarpet
        );
    }

    /**
     * @notice Calculate minimum output amounts for withdrawal with slippage protection
     * @param pos MultiPositionManager address
     * @param shares Number of shares to burn
     * @param maxSlippage Maximum slippage in basis points (10000 = 100%)
     * @return outMin Array of minimum amounts for each base and limit position
     */
    function getOutMinForShares(address pos, uint256 shares, uint256 maxSlippage)
        external
        view
        returns (uint256[2][] memory outMin)
    {
        // if (maxSlippage > 10000) revert MaxSlippageExceeded();
        MultiPositionManager manager = MultiPositionManager(payable(pos));
        return SimpleLensInMin.getOutMinForShares(manager, shares, maxSlippage);
    }

    // InitialDepositWithSwapParams, PreviewContext, and InitialDepositParams structs moved to libraries

    /**
     * @dev Calculate consumed tokens by base positions
     */
    function _calculateConsumedTokens(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        uint160 sqrtPriceX96
    ) private pure returns (uint256 consumedToken0, uint256 consumedToken1) {
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
    }

    /**
     * @notice Calculate which token and how much to deposit/withdraw to achieve desired ratio
     * @param manager The MultiPositionManager contract
     * @param desiredRatio The desired ratio of token0 value to total value (1e18 = 100% token0, 5e17 = 50% token0)
     * @param isDeposit True to fix ratio via deposit, false to fix via withdrawal
     * @return isToken0 True if need to deposit/withdraw token0, false for token1
     * @return amount The amount of token to deposit/withdraw
     */
    function ratioFix(MultiPositionManager manager, uint256 desiredRatio, bool isDeposit)
        external
        view
        returns (bool isToken0, uint256 amount)
    {
        // Cannot achieve exactly 0% or 100% through deposits (would require infinite amount)
        if (isDeposit && (desiredRatio == 0 || desiredRatio == 1e18)) {
            revert InvalidRatioForDeposit();
        }

        return SimpleLensRatioUtils.ratioFix(manager, desiredRatio, isDeposit);
    }

    /**
     * @notice Calculate the corresponding token amount needed to maintain the current ratio, preview expected positions, and calculate inMin for slippage protection
     * @param manager The MultiPositionManager contract
     * @param isToken0 True if the provided amount is token0, false if token1
     * @param amount The amount of the token you want to deposit
     * @param maxSlippage Maximum slippage in basis points (10000 = 100%)
     * @return otherAmount The amount of the other token needed to maintain the current ratio
     * @return inMin Array of minimum amounts for each base and limit position
     * @return expectedPositions Array of PositionStats showing expected state after deposit
     */
    function getAmountsForExactRatioDeposit(
        MultiPositionManager manager,
        bool isToken0,
        uint256 amount,
        uint256 maxSlippage
    )
        external
        view
        returns (
            uint256 otherAmount,
            uint256[2][] memory inMin,
            SimpleLensRatioUtils.PositionStats[] memory expectedPositions
        )
    {
        // if (maxSlippage > 10000) revert MaxSlippageExceeded();

        // Calculate other amount needed
        otherAmount = SimpleLensRatioUtils.getAmountsForDeposit(manager, isToken0, amount);

        // Get current positions
        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        expectedPositions = new SimpleLensRatioUtils.PositionStats[](ranges.length);

        uint256 basePositionsLength = manager.basePositionsLength();

        if (basePositionsLength == 0) {
            return (otherAmount, inMin, expectedPositions);
        }

        // Prepare amounts for deposit
        uint256 deposit0 = isToken0 ? amount : otherAmount;
        uint256 deposit1 = isToken0 ? otherAmount : amount;

        // Calculate expected positions
        expectedPositions = SimpleLensRatioUtils.calculateExpectedPositionsAfterDeposit(
            manager, ranges, positionData, deposit0, deposit1
        );

        // Calculate inMin with slippage protection
        uint256 limitPositionsLength = manager.limitPositionsLength();
        inMin = new uint256[2][](basePositionsLength + limitPositionsLength);

        inMin = SimpleLensRatioUtils.calculateDirectDepositInMin(
            manager, deposit0, deposit1, maxSlippage, basePositionsLength, inMin
        );
    }

    /**
     * @notice Calculate amounts and preview positions for compound with optional deposit and swap
     * @dev Works for all scenarios: fee compound only, deposit+compound, with/without optimal swap
     *      Factors in: fees (from zeroBurn) + idle vault balance + deposit amounts
     * @param pos MultiPositionManager address
     * @param deposit0 Amount of token0 being deposited (0 for fee-only compound)
     * @param deposit1 Amount of token1 being deposited (0 for fee-only compound)
     * @param maxSlippageBps Maximum slippage in basis points (10000 = 100%)
     * @param needsSwap Whether to calculate and apply optimal swap (false = no swap, true = with swap)
     * @return finalAmount0 Final amount of token0 after optional swap (total available if no swap)
     * @return finalAmount1 Final amount of token1 after optional swap (total available if no swap)
     * @return swapParams Swap parameters (direction, amount, target weights)
     * @return inMin Array of minimum amounts for each base and limit position
     * @return expectedPositions Array of PositionStats showing expected state after compound
     */
    function getAmountsForDepositAndCompound(
        address pos,
        uint256 deposit0,
        uint256 deposit1,
        uint256 maxSlippageBps,
        bool needsSwap
    )
        external
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            SimpleLensRatioUtils.PositionStats[] memory expectedPositions
        )
    {
        // if (maxSlippageBps > 10000) revert MaxSlippageExceeded();

        MultiPositionManager manager = MultiPositionManager(payable(pos));
        return
            SimpleLensRatioUtils.getAmountsForDepositAndCompound(manager, deposit0, deposit1, maxSlippageBps, needsSwap);
    }

    /**
     * @notice Simulate expected positions from depositing amounts and rebalancing with specified parameters
     * @dev Calculates what positions will look like after depositing tokens and performing a rebalance
     * @param manager The MultiPositionManager contract
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param maxSlippageOutMin Maximum slippage for burning old positions in basis points (10000 = 100%)
     * @param maxSlippageInMin Maximum slippage for minting new positions in basis points (10000 = 100%)
     * @param rebalanceParams Parameters for the rebalance (strategy, ticks, weights, etc.)
     * @return outMin Array of minimum amounts for withdrawing from current positions
     * @return inMin Array of minimum amounts for depositing to new positions (slippage protection)
     * @return expectedPositions Array of PositionStats showing expected state after deposit + rebalance
     */
    function getAmountsForCustomDepositAndRebalance(
        IMultiPositionManager manager,
        uint256 amount0,
        uint256 amount1,
        uint256 maxSlippageOutMin,
        uint256 maxSlippageInMin,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    )
        external
        view
        returns (
            uint256[2][] memory outMin,
            uint256[2][] memory inMin,
            SimpleLensRatioUtils.PositionStats[] memory expectedPositions
        )
    {
        // if (maxSlippageOutMin > 10000 || maxSlippageInMin > 10000) revert MaxSlippageExceeded();

        MultiPositionManager mpm = MultiPositionManager(payable(address(manager)));

        // Scope 1: Calculate outMin
        {
            uint256 totalShares = mpm.totalSupply();
            outMin = totalShares > 0
                ? SimpleLensInMin.getOutMinForShares(mpm, totalShares, maxSlippageOutMin)
                : new uint256[2][](0);
        }

        // Scope 2: Simulate deposit and rebalance
        {
            (uint256 currentTotal0, uint256 currentTotal1,,) = manager.getTotalAmounts();
            (inMin, expectedPositions) = SimpleLensLibrary.simulateDepositAndRebalance(
                mpm, currentTotal0 + amount0, currentTotal1 + amount1, rebalanceParams, maxSlippageInMin
            );
        }
    }
}
