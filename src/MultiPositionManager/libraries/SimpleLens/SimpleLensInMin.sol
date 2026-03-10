// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MultiPositionManager} from "../../MultiPositionManager.sol";
import {IMultiPositionManager} from "../../interfaces/IMultiPositionManager.sol";
import {ILiquidityStrategy} from "../../strategies/ILiquidityStrategy.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleLensRatioUtils} from "./SimpleLensRatioUtils.sol";
import {SimpleLensInMinPreview} from "./SimpleLensInMinPreview.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolManagerUtils} from "../PoolManagerUtils.sol";
import {RebalanceLogic} from "../RebalanceLogic.sol";
import {WithdrawLogic} from "../WithdrawLogic.sol";
import {PositionLogic} from "../PositionLogic.sol";
import {LiquidityAmountsCapped} from "../LiquidityAmountsCapped.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library SimpleLensInMin {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Parameters for getOutMinAndInMinForRebalance
    struct RebalanceMinParams {
        MultiPositionManager manager;
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        bool swap;
        uint256 maxSlippageOutMin;
        uint256 maxSlippageInMin;
        bool deductFees;
    }

    struct CalculateOtherAmountParams {
        address strategyAddress;
        int24 resolvedCenterTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        uint160 sqrtPriceX96;
        bool isToken0;
        uint256 amount;
    }

    struct LimitPositionsParams {
        uint24 limitWidth;
        int24 currentTick;
        int24 tickSpacing;
        uint256 maxSlippageBps;
        uint160 sqrtPriceX96;
        uint256 totalAmount0;
        uint256 totalAmount1;
    }

    struct InMinRebalanceParams {
        MultiPositionManager manager;
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        bool swap;
        uint256 maxSlippage;
        bool deductFees;
    }

    struct InitialDepositWithSwapParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        uint256 maxSlippageBps;
        uint256 amount0;
        uint256 amount1;
    }

    struct RebalancePreviewParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        bool swap;
    }

    struct RebalancePreview {
        // Input parameters
        IMultiPositionManager.Range[] ranges;
        address strategy;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        // Calculated liquidities per position
        uint128[] liquidities;
        // Expected position data after rebalance
        SimpleLensRatioUtils.PositionStats[] expectedPositions;
        // Total amounts after rebalance
        uint256 expectedTotal0;
        uint256 expectedTotal1;
        // Swap details (if swap is performed)
        bool swapToken0;
        uint256 swapAmount;
        uint256 expectedAmountOut;
        // Post-swap amounts (if swap)
        uint256 postSwapAmount0;
        uint256 postSwapAmount1;
    }

    struct PreviewData {
        uint256 total0;
        uint256 total1;
        uint256 totalFee0;
        uint256 totalFee1;
        uint256 unusedAmount0;
        uint256 unusedAmount1;
        uint256 totalSupply;
        uint256 totalPositions;
    }

    struct WithdrawPreviewResult {
        uint256 sharesWithdrawn;
        uint256 positionSharesBurned;
        uint256[2][] outMin;
        RebalancePreview rebalancePreview;
        bool isFullBurn;
        uint256[2][] outMinForRebalance;
    }

    struct DensityCalcParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        bool useAssetWeights;
        int24 currentTick;
        int24 tickSpacing;
    }

    struct InMinCalcData {
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 tickSpacing;
        uint256 maxSlippage;
    }

    struct InMinCalcState {
        uint256 totalWeightedToken0;
        uint256 totalWeightedToken1;
        uint128 maxLiquidityFromToken0;
        uint128 maxLiquidityFromToken1;
        uint128 totalLiquidity;
        uint256 slippageMultiplier;
    }

    struct PreviewContext {
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 resolvedCenter;
        uint256 finalAmount0;
        uint256 finalAmount1;
    }

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
            // Calculate expected amounts for this position based on share ratio
            uint256 positionLiquidity = uint256(positionData[i].liquidity);
            if (positionLiquidity == 0) {
                outMin[i] = [uint256(0), uint256(0)];
                continue;
            }

            // Pro-rata share of liquidity
            uint128 liquidityToBurn = uint128(FullMath.mulDiv(positionLiquidity, shares, totalSupply));

            // Get amounts for this liquidity
            (uint256 amt0, uint256 amt1) = PoolManagerUtils.getAmountsForLiquidity(
                manager.poolManager(), manager.poolKey(), ranges[i], liquidityToBurn
            );

            // Apply slippage protection (round down for conservative minimums)
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
        return SimpleLensInMinPreview.getOutMinForShares(manager, shares, maxSlippage);
    }

    function calculateInMinForRebalance(InMinRebalanceParams memory params)
        external
        view
        returns (uint256[2][] memory)
    {
        return _calculateInMinInternal(params);
    }

    /**
     * @notice Calculate minimum input amounts from existing ranges and weights
     */
    function calculateInMinFromExistingData(
        IMultiPositionManager.Range[] memory ranges,
        uint256[] memory weights,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 maxSlippage
    ) external pure returns (uint256[2][] memory inMin) {
        return _calculateInMinFromExistingData(ranges, weights, amount0, amount1, sqrtPriceX96, maxSlippage);
    }

    function _calculateInMinFromExistingData(
        IMultiPositionManager.Range[] memory ranges,
        uint256[] memory weights,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 maxSlippage
    ) private pure returns (uint256[2][] memory inMin) {
        uint256 rangesLength = ranges.length;
        inMin = new uint256[2][](rangesLength);

        if (rangesLength == 0) return inMin;

        InMinCalcState memory state;

        // First pass: calculate weighted token requirements
        for (uint256 i = 0; i < rangesLength; i++) {
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) continue;

            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 amount0For1e18, uint256 amount1For1e18) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, 1e18);

            state.totalWeightedToken0 += (amount0For1e18 * weights[i]) / 1e18;
            state.totalWeightedToken1 += (amount1For1e18 * weights[i]) / 1e18;
        }

        // Calculate total liquidity based on limiting token
        {
            state.maxLiquidityFromToken0 = state.totalWeightedToken0 > 0
                ? uint128((amount0 * 1e18) / state.totalWeightedToken0)
                : type(uint128).max;
            state.maxLiquidityFromToken1 = state.totalWeightedToken1 > 0
                ? uint128((amount1 * 1e18) / state.totalWeightedToken1)
                : type(uint128).max;

            state.totalLiquidity = state.maxLiquidityFromToken0 < state.maxLiquidityFromToken1
                ? state.maxLiquidityFromToken0
                : state.maxLiquidityFromToken1;
        }

        // Apply slippage protection
        state.slippageMultiplier = 10000 - maxSlippage;

        // Second pass: calculate inMin for each position
        for (uint256 i = 0; i < rangesLength; i++) {
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) {
                inMin[i] = [uint256(0), uint256(0)];
                continue;
            }

            // Check if this is a carpet position (extreme ticks)
            // Carpet positions use min/max usable ticks and should have minimal inMin
            bool isCarpet = _isCarpetPosition(ranges[i].lowerTick, ranges[i].upperTick);

            if (isCarpet) {
                // For carpet positions, use minimal inMin (1 wei)
                inMin[i] = [uint256(0), uint256(0)];
                continue;
            }

            uint128 positionLiquidity = uint128((uint256(state.totalLiquidity) * weights[i]) / 1e18);

            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 amount0For, uint256 amount1For) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, positionLiquidity);

            inMin[i] = [
                FullMath.mulDiv(amount0For, state.slippageMultiplier, 10000),
                FullMath.mulDiv(amount1For, state.slippageMultiplier, 10000)
            ];
        }
    }

    /**
     * @notice Check if a position is a carpet position (extreme ticks)
     */
    function _isCarpetPosition(int24 lowerTick, int24 upperTick) private pure returns (bool) {
        // Check if lower tick is extremely low (< -800000)
        // Check if upper tick is extremely high (> 800000)
        return (lowerTick < -800000 || upperTick > 800000);
    }

    function _calculateInMinInternal(InMinRebalanceParams memory params) private view returns (uint256[2][] memory) {
        DensityCalcParams memory densityParams;
        InMinCalcData memory calcData;

        // Block 1: Get amounts and estimate post-swap if needed
        {
            (uint256 amount0, uint256 amount1) = _getTotalAmountsForRebalance(params.manager, params.deductFees);

            // If swap is involved, estimate post-swap amounts
            if (params.swap) {
                (amount0, amount1) = _estimatePostSwapAmounts(params, amount0, amount1);
            }

            calcData.amount0 = amount0;
            calcData.amount1 = amount1;
        }

        // Block 2: Get pool state
        {
            PoolKey memory poolKey = params.manager.poolKey();
            IPoolManager poolManager = params.manager.poolManager();
            (calcData.sqrtPriceX96, calcData.currentTick,,) = poolManager.getSlot0(poolKey.toId());
            calcData.tickSpacing = poolKey.tickSpacing;
            calcData.maxSlippage = params.maxSlippage;
        }

        // Block 3: Prepare density params
        {
            int24 resolvedCenterTick =
                RebalanceLogic.resolveAndClampCenterTick(params.centerTick, calcData.currentTick, calcData.tickSpacing);

            // For proportional weights, calculate from post-swap amounts (matches RebalanceLogic behavior)
            // When swap=true, amounts are already post-swap. When swap=false, amounts are current.
            // This ensures inMin calculation uses the same weights that RebalanceLogic will use.
            uint256 weight0 = params.weight0;
            uint256 weight1 = params.weight1;
            if (params.weight0 == 0 && params.weight1 == 0) {
                (weight0, weight1) = RebalanceLogic.calculateWeightsFromAmounts(
                    calcData.amount0, calcData.amount1, calcData.sqrtPriceX96
                );
            }

            densityParams = DensityCalcParams({
                strategyAddress: params.strategyAddress,
                centerTick: resolvedCenterTick,
                ticksLeft: params.ticksLeft,
                ticksRight: params.ticksRight,
                weight0: weight0,
                weight1: weight1,
                useCarpet: params.useCarpet,
                useAssetWeights: (params.weight0 == 0 && params.weight1 == 0),
                currentTick: calcData.currentTick,
                tickSpacing: calcData.tickSpacing
            });
        }

        return _calculateInMinWithStructs(densityParams, calcData);
    }

    function _calculateInMinWithStructs(DensityCalcParams memory densityParams, InMinCalcData memory calcData)
        private
        view
        returns (uint256[2][] memory)
    {
        int24[] memory lowerTicks;
        int24[] memory upperTicks;
        uint256[] memory weights;

        // Step 1: Generate ranges
        {
            (lowerTicks, upperTicks) =
                _callGenerateRanges(densityParams.strategyAddress, densityParams, calcData.tickSpacing);
        }

        // Step 2: Calculate weights
        {
            weights = _callCalculateDensities(densityParams, lowerTicks, upperTicks);
        }

        // Step 3: Calculate final inMin
        {
            return _calculateInMinArrayFromAmounts(
                lowerTicks,
                upperTicks,
                weights,
                calcData.amount0,
                calcData.amount1,
                calcData.sqrtPriceX96,
                calcData.maxSlippage,
                densityParams.useAssetWeights
            );
        }
    }

    function calculateInMinArrayFromAmounts(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        uint256[] memory weights,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 maxSlippage,
        bool useAssetWeights
    ) external pure returns (uint256[2][] memory inMin) {
        return _calculateInMinArrayFromAmounts(
            lowerTicks, upperTicks, weights, amount0, amount1, sqrtPriceX96, maxSlippage, useAssetWeights
        );
    }

    function _calculateInMinArrayFromAmounts(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        uint256[] memory weights,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 maxSlippage,
        bool useAssetWeights
    ) private pure returns (uint256[2][] memory inMin) {
        inMin = new uint256[2][](lowerTicks.length);
        if (lowerTicks.length == 0) return inMin;

        // Use RebalanceLogic's allocation algorithm to match actual rebalance behavior
        RebalanceLogic.AllocationData memory data;
        data.token0Allocations = new uint256[](lowerTicks.length);
        data.token1Allocations = new uint256[](lowerTicks.length);
        data.currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Convert ticks to ranges for RebalanceLogic functions
        IMultiPositionManager.Range[] memory baseRanges = new IMultiPositionManager.Range[](lowerTicks.length);
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            baseRanges[i] = IMultiPositionManager.Range(lowerTicks[i], upperTicks[i]);
        }

        // Step 1: Calculate initial allocations based on weights
        // Pass useCarpet=false and tickSpacing=1 as this function doesn't use carpet detection
        // (carpet detection is handled separately in _convertAllocationsToInMin)
        RebalanceLogic.calculateInitialAllocations(data, baseRanges, weights, sqrtPriceX96, false, 1);

        // Step 2: Scale allocations proportionally
        RebalanceLogic.scaleAllocations(data, amount0, amount1, useAssetWeights);

        // Step 3: Fix current range and redistribute (only for proportional weights)
        if (useAssetWeights && data.hasCurrentRange) {
            RebalanceLogic.fixCurrentRangeAndRedistribute(data, baseRanges, sqrtPriceX96);
        }

        // Step 4: Convert allocations to inMin with slippage using round-trip calculation
        uint256 slippageMultiplier = 10000 - maxSlippage;
        _convertAllocationsToInMin(inMin, data, lowerTicks, upperTicks, sqrtPriceX96, slippageMultiplier);

        return inMin;
    }

    /**
     * @notice Convert token allocations to inMin values using round-trip calculation
     * @dev This matches actual liquidity minting behavior by calculating liquidity from allocations
     *      then getting actual amounts that will be consumed
     */
    function _convertAllocationsToInMin(
        uint256[2][] memory inMin,
        RebalanceLogic.AllocationData memory data,
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        uint160 sqrtPriceX96,
        uint256 slippageMultiplier
    ) private pure {
        uint256 length = lowerTicks.length;

        for (uint256 i = 0; i < length; i++) {
            // Check if this is a carpet position (extreme ticks)
            // Carpet positions use min/max usable ticks and should have minimal inMin
            bool isCarpet = _isCarpetPosition(lowerTicks[i], upperTicks[i]);
            if (isCarpet) {
                // For carpet positions, use minimal inMin (0)
                inMin[i] = [uint256(0), uint256(0)];
                continue;
            }

            // Round-trip calculation to get actual consumption amounts:
            // 1. Calculate sqrtPrice bounds
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTicks[i]);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTicks[i]);

            // 2. Get liquidity that will be minted (constraining factor)
            uint128 liquidity = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, data.token0Allocations[i], data.token1Allocations[i]
            );

            // 3. Get actual amounts that will be consumed
            (uint256 actualAmount0, uint256 actualAmount1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidity);

            // 4. Apply slippage to actual consumption (not allocated amounts)
            inMin[i] = [
                FullMath.mulDiv(actualAmount0, slippageMultiplier, 10000),
                FullMath.mulDiv(actualAmount1, slippageMultiplier, 10000)
            ];
        }
    }

    function _getTotalAmountsForRebalance(MultiPositionManager manager, bool deductFees)
        private
        view
        returns (uint256 total0, uint256 total1)
    {
        uint256 fee0;
        uint256 fee1;
        (total0, total1, fee0, fee1) = manager.getTotalAmounts();

        // When compoundFees=false, fees are claimed before rebalance, so subtract them
        if (deductFees) {
            total0 = total0 > fee0 ? total0 - fee0 : 0;
            total1 = total1 > fee1 ? total1 - fee1 : 0;
        }
    }

    function _estimatePostSwapAmounts(InMinRebalanceParams memory params, uint256 amount0, uint256 amount1)
        private
        view
        returns (uint256, uint256)
    {
        // Get pool state
        PoolKey memory poolKey = params.manager.poolKey();
        IPoolManager poolManager = params.manager.poolManager();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Calculate target weights using helper function to avoid stack too deep
        (uint256 weight0, uint256 weight1) = _calculateTargetWeights(params, poolKey, sqrtPriceX96, currentTick);

        // Estimate post-swap amounts (simplified calculation)
        // This is an approximation - actual swap will depend on pool liquidity
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96);

        uint256 total0InToken1 = amount0 + FullMath.mulDiv(amount1, 1e18, price);
        uint256 targetAmount0 = FullMath.mulDiv(total0InToken1, weight0, weight0 + weight1);
        uint256 targetAmount1 = FullMath.mulDiv(total0InToken1, weight1, weight0 + weight1);

        // Convert back to token amounts
        targetAmount1 = FullMath.mulDiv(targetAmount1, price, 1e18);

        return (targetAmount0, targetAmount1);
    }

    function _calculateTargetWeights(
        InMinRebalanceParams memory params,
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        int24 currentTick
    ) private view returns (uint256 weight0, uint256 weight1) {
        // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
        int24 centerTick =
            RebalanceLogic.resolveAndClampCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);

        // Calculate target weights from strategy (not from current amounts)
        weight0 = params.weight0;
        weight1 = params.weight1;
        if (params.weight0 == 0 && params.weight1 == 0) {
            (weight0, weight1) = RebalanceLogic.calculateWeightsFromStrategy(
                ILiquidityStrategy(params.strategyAddress),
                centerTick,
                params.ticksLeft,
                params.ticksRight,
                poolKey.tickSpacing,
                params.useCarpet,
                sqrtPriceX96,
                currentTick
            );
        }
    }

    function _callGenerateRanges(address strategyAddress, DensityCalcParams memory params, int24 tickSpacing)
        private
        view
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        ILiquidityStrategy strategy = ILiquidityStrategy(strategyAddress);

        (lowerTicks, upperTicks) = strategy.generateRanges(
            params.centerTick, params.ticksLeft, params.ticksRight, tickSpacing, params.useCarpet
        );
    }

    function _getMinUsableTick(int24 tickSpacing) private pure returns (int24) {
        return (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
    }

    function _getMaxUsableTick(int24 tickSpacing) private pure returns (int24) {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }

    function _callCalculateDensities(
        DensityCalcParams memory params,
        int24[] memory lowerTicks,
        int24[] memory upperTicks
    ) private view returns (uint256[] memory) {
        // All parameters are now in the struct to avoid stack too deep
        return ILiquidityStrategy(params.strategyAddress).calculateDensities(
            lowerTicks,
            upperTicks,
            params.currentTick,
            params.centerTick,
            params.ticksLeft,
            params.ticksRight,
            params.weight0,
            params.weight1,
            params.useCarpet,
            params.tickSpacing,
            params.useAssetWeights
        );
    }

    // Specialized struct for calculating ranges from a strategy
    struct RangeCalculationParams {
        address strategyAddress;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint24 limitWidth;
        int24 tickSpacing;
        bool useCarpet;
    }

    /**
     * @notice Calculate ranges from strategy for rebalance preview
     */
    function calculateRangesFromStrategy(RangeCalculationParams memory params)
        external
        view
        returns (IMultiPositionManager.Range[] memory ranges)
    {
        ILiquidityStrategy strategy = ILiquidityStrategy(params.strategyAddress);

        (int24[] memory lowerTicks, int24[] memory upperTicks) = strategy.generateRanges(
            params.centerTick, params.ticksLeft, params.ticksRight, params.tickSpacing, params.useCarpet
        );

        // Convert to Range[]
        ranges = _buildRangeArray(lowerTicks, upperTicks);

        // Apply carpet if requested
        if (params.useCarpet && ranges.length >= 2) {
            ranges[0].lowerTick = _getMinUsableTick(params.tickSpacing);
            ranges[ranges.length - 1].upperTick = _getMaxUsableTick(params.tickSpacing);
        }

        return ranges;
    }

    /**
     * @notice Internal helper to build IMultiPositionManager.Range array
     */
    function _buildRangeArray(int24[] memory lowerTicks, int24[] memory upperTicks)
        private
        pure
        returns (IMultiPositionManager.Range[] memory ranges)
    {
        ranges = new IMultiPositionManager.Range[](lowerTicks.length);
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            ranges[i] = IMultiPositionManager.Range({lowerTick: lowerTicks[i], upperTick: upperTicks[i]});
        }
    }

    /**
     * @notice Public function to get all outMin and inMin for rebalance (struct version)
     * @param params RebalanceMinParams struct containing all parameters
     */
    function getOutMinAndInMinForRebalance(RebalanceMinParams memory params)
        external
        view
        returns (uint256[2][] memory outMin, uint256[2][] memory inMin)
    {
        // In proportional mode (weights 0,0), force limitWidth to 0
        // Limit positions don't make sense when weights are derived from amounts
        uint24 limitWidth = params.limitWidth;
        if (params.weight0 == 0 && params.weight1 == 0) {
            limitWidth = 0;
        }

        outMin = _calculateOutMinForRebalance(params.manager, params.maxSlippageOutMin);

        InMinRebalanceParams memory inMinParams;
        inMinParams.manager = params.manager;
        inMinParams.strategyAddress = params.strategyAddress;
        inMinParams.centerTick = params.centerTick;
        inMinParams.ticksLeft = params.ticksLeft;
        inMinParams.ticksRight = params.ticksRight;
        inMinParams.limitWidth = limitWidth;
        inMinParams.weight0 = params.weight0;
        inMinParams.weight1 = params.weight1;
        inMinParams.useCarpet = params.useCarpet;
        inMinParams.swap = params.swap;
        inMinParams.maxSlippage = params.maxSlippageInMin;
        inMinParams.deductFees = params.deductFees;

        inMin = _calculateInMinInternal(inMinParams);

        return (outMin, inMin);
    }

    /**
     * @notice Backward-compatible wrapper for getOutMinAndInMinForRebalance
     * @dev Converts positional arguments to RebalanceMinParams struct with deductFees=false
     */
    function getOutMinAndInMinForRebalance(
        MultiPositionManager manager,
        address strategyAddress,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        uint24 limitWidth,
        uint256 weight0,
        uint256 weight1,
        bool useCarpet,
        bool swap,
        uint256 maxSlippageOutMin,
        uint256 maxSlippageInMin
    ) external view returns (uint256[2][] memory outMin, uint256[2][] memory inMin) {
        // In proportional mode (weights 0,0), force limitWidth to 0
        // Limit positions don't make sense when weights are derived from amounts
        uint24 actualLimitWidth = limitWidth;
        if (weight0 == 0 && weight1 == 0) {
            actualLimitWidth = 0;
        }

        outMin = _calculateOutMinForRebalance(manager, maxSlippageOutMin);

        InMinRebalanceParams memory inMinParams;
        inMinParams.manager = manager;
        inMinParams.strategyAddress = strategyAddress;
        inMinParams.centerTick = centerTick;
        inMinParams.ticksLeft = ticksLeft;
        inMinParams.ticksRight = ticksRight;
        inMinParams.limitWidth = actualLimitWidth;
        inMinParams.weight0 = weight0;
        inMinParams.weight1 = weight1;
        inMinParams.useCarpet = useCarpet;
        inMinParams.swap = swap;
        inMinParams.maxSlippage = maxSlippageInMin;
        inMinParams.deductFees = false;

        inMin = _calculateInMinInternal(inMinParams);

        return (outMin, inMin);
    }

    function _calculateOutMinForRebalance(MultiPositionManager manager, uint256 maxSlippage)
        private
        view
        returns (uint256[2][] memory outMin)
    {
        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        return PoolManagerUtils.calculateOutMinForRebalance(
            manager.poolManager(), manager.poolKey(), ranges, positionData, maxSlippage
        );
    }

    function calculateSwapAndPreview(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        InitialDepositWithSwapParams calldata params
    )
        external
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            RebalancePreview memory preview
        )
    {
        return SimpleLensInMinPreview.calculateSwapAndPreview(poolManager, poolKey, params);
    }

    function _buildPreviewFromRangesAndLiquidities(
        IPoolManager /* poolManager */,
        PoolKey memory /* poolKey */,
        IMultiPositionManager.Range[] memory ranges,
        uint128[] memory liquidities,
        InitialDepositWithSwapParams calldata params,
        PreviewContext memory ctx,
        SimpleLensRatioUtils.SwapParams memory /* swapParams */
    ) private pure returns (uint256[2][] memory inMin, RebalancePreview memory preview) {
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

        // Calculate expected positions
        // For initial deposit with swap, if limitWidth > 0, last 2 positions are limits
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
        InitialDepositWithSwapParams calldata params,
        uint160 sqrtPriceX96,
        int24 resolvedCenter,
        int24 tickSpacing,
        int24 currentTick
    )
        private
        view
        returns (SimpleLensRatioUtils.SwapParams memory swapParams, uint256 finalAmount0, uint256 finalAmount1)
    {
        // Calculate target weights
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

        // Calculate optimal swap using RebalanceLogic
        (bool swapToken0, uint256 swapAmount) = RebalanceLogic.calculateOptimalSwap(
            params.amount0, params.amount1, sqrtPriceX96, swapParams.weight0, swapParams.weight1
        );

        // Build SwapParams struct
        swapParams.swapToken0 = swapToken0;
        swapParams.swapAmount = swapAmount;

        // Calculate final amounts after theoretical swap
        finalAmount0 = params.amount0;
        finalAmount1 = params.amount1;

        if (swapAmount > 0) {
            if (swapToken0) {
                // Swapping token0 for token1
                uint256 amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(swapAmount, uint256(sqrtPriceX96), 1 << 96), uint256(sqrtPriceX96), 1 << 96
                );
                finalAmount0 -= swapAmount;
                finalAmount1 += amountOut;
            } else {
                // Swapping token1 for token0
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
        RebalancePreview memory preview,
        uint256 baseLength
    ) private pure {
        // Get current price for value calculations
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

    /**
     * @notice Get unused token balances from manager
     * @param manager The MultiPositionManager
     * @param poolKey The pool key
     * @return unusedAmount0 Unused token0 balance
     * @return unusedAmount1 Unused token1 balance
     */
    function getUnusedBalances(MultiPositionManager manager, PoolKey memory poolKey)
        internal
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

    /**
     * @notice Simulate rebalance positions
     * @param manager The MultiPositionManager
     * @param totalAmount0 Total token0 to rebalance
     * @param totalAmount1 Total token1 to rebalance
     * @param params Rebalance parameters
     * @return preview Rebalance preview
     */
    function simulateRebalance(
        MultiPositionManager manager,
        uint256 totalAmount0,
        uint256 totalAmount1,
        IMultiPositionManager.RebalanceParams memory params
    ) internal view returns (RebalancePreview memory preview) {
        IPoolManager poolManager = manager.poolManager();
        PoolKey memory poolKey = manager.poolKey();

        // Get pool state and resolve center
        PreviewContext memory ctx;
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

        // Add limit positions (inline logic since external function can't be called internally)
        IMultiPositionManager.Range[] memory allRanges;
        uint128[] memory allLiquidities;

        if (params.limitWidth > 0) {
            // Calculate limit ranges using PositionLogic
            (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit) =
                PositionLogic.calculateLimitRanges(params.limitWidth, baseRanges, poolKey.tickSpacing, ctx.currentTick);

            // Create arrays for base + 2 limit positions
            allRanges = new IMultiPositionManager.Range[](baseRanges.length + 2);
            allLiquidities = new uint128[](baseRanges.length + 2);

            // Copy base ranges and liquidities
            for (uint256 i = 0; i < baseRanges.length; i++) {
                allRanges[i] = baseRanges[i];
                allLiquidities[i] = baseLiquidities[i];
            }

            // Calculate remainders from base positions
            (uint256 remainderToken0, uint256 remainderToken1) =
                _calculateRemainders(baseRanges, baseLiquidities, ctx.sqrtPriceX96, ctx.finalAmount0, ctx.finalAmount1);

            // Add limit positions
            allRanges[baseRanges.length] = lowerLimit;
            allRanges[baseRanges.length + 1] = upperLimit;

            // Lower limit (below current tick) gets remainder token1
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

            // Upper limit (above current tick) gets remainder token0
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
            // No limit positions
            allRanges = baseRanges;
            allLiquidities = baseLiquidities;
        }

        // Build preview with all positions (base + limit)
        preview.ranges = allRanges;
        preview.strategy = params.strategy;
        preview.centerTick = ctx.resolvedCenter;
        preview.ticksLeft = params.tLeft;
        preview.ticksRight = params.tRight;
        preview.liquidities = allLiquidities;
        preview.postSwapAmount0 = ctx.finalAmount0;
        preview.postSwapAmount1 = ctx.finalAmount1;

        // Calculate expected positions (now includes base + limit positions)
        // baseRanges.length is the count of base positions; limit positions are at indices >= baseRanges.length
        preview.expectedPositions = new SimpleLensRatioUtils.PositionStats[](allRanges.length);
        _populateExpectedPositions(allRanges, allLiquidities, ctx.sqrtPriceX96, preview, baseRanges.length);
    }

    /**
     * @notice Create zero-filled outMin and outMinForRebalance arrays
     * @param totalPositions Number of positions
     * @return outMin Zero-filled array for withdrawal
     * @return outMinForRebalance Zero-filled array for rebalance
     */
    function createZeroOutMinArrays(uint256 totalPositions)
        internal
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

    /**
     * @notice Create outMinForRebalance array based on full burn status
     * @param isFullBurn Whether all positions will be burned
     * @param totalPositions Number of positions (ignored if isFullBurn)
     * @return outMinForRebalance Empty array if full burn, zero-filled array otherwise
     */
    function createOutMinForRebalanceArray(bool isFullBurn, uint256 totalPositions)
        internal
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

    /**
     * @notice Internal implementation of previewWithdrawCustom
     * @param manager The MultiPositionManager
     * @param amount0Desired Amount of token0 to withdraw
     * @param amount1Desired Amount of token1 to withdraw
     * @param maxSlippage Maximum slippage for outMin calculation
     * @param previewRebalance If true, simulates rebalance after withdrawal
     * @param rebalanceParams Parameters for rebalance simulation
     * @return result Preview result with all withdrawal details
     */
    function previewWithdrawCustomInternal(
        MultiPositionManager manager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) internal view returns (WithdrawPreviewResult memory result) {
        return SimpleLensInMinPreview.previewWithdrawCustomInternal(
            manager, amount0Desired, amount1Desired, maxSlippage, previewRebalance, rebalanceParams
        );
    }

    /**
     * @notice Handle PATH 1 & 2 (no positions burned)
     */
    function _handlePath1And2(
        WithdrawPreviewResult memory result,
        MultiPositionManager manager,
        PreviewData memory data,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) private view {
        result.positionSharesBurned = 0;
        result.isFullBurn = false;

        // Create zero outMin and outMinForRebalance arrays for PATH 1/2 using library
        (result.outMin, result.outMinForRebalance) = createZeroOutMinArrays(data.totalPositions);

        // If rebalance preview requested, simulate new positions
        if (previewRebalance && rebalanceParams.strategy != address(0)) {
            uint256 r0 = (data.unusedAmount0 + data.totalFee0) - amount0Desired;
            uint256 r1 = (data.unusedAmount1 + data.totalFee1) - amount1Desired;
            result.rebalancePreview = simulateRebalance(manager, r0, r1, rebalanceParams);
        }
    }

    /**
     * @notice Handle PATH 3 (partial burn) with optional rebalance preview
     */
    function _handlePath3WithRebalance(
        WithdrawPreviewResult memory result,
        MultiPositionManager manager,
        PreviewData memory data,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        bool previewRebalance,
        IMultiPositionManager.RebalanceParams memory rebalanceParams
    ) private view {
        result.positionSharesBurned =
            WithdrawLogic.calculatePositionSharesToBurnForSimpleLens(address(manager), amount0Desired, amount1Desired);

        // Calculate outMin using positionSharesBurned for PATH 3
        result.outMin = _calculateOutMinForShares(manager, result.positionSharesBurned, maxSlippage);

        // Check if this is a full burn
        result.isFullBurn = (result.positionSharesBurned == data.totalSupply);

        // Create outMinForRebalance based on whether it's a full burn using library
        result.outMinForRebalance = createOutMinForRebalanceArray(result.isFullBurn, data.totalPositions);

        if (previewRebalance && rebalanceParams.strategy != address(0)) {
            uint256 r0 = data.total0 - amount0Desired;
            uint256 r1 = data.total1 - amount1Desired;

            result.rebalancePreview = simulateRebalance(manager, r0, r1, rebalanceParams);
        }
    }

    function calculateOtherAmountInline(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        CalculateOtherAmountParams memory params
    ) external view returns (uint256 otherAmount) {
        return SimpleLensInMinPreview.calculateOtherAmountInline(poolManager, poolKey, params);
    }

    function _generateRangesAndWeights(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        CalculateOtherAmountParams memory params
    ) private view returns (int24[] memory lowerTicks, int24[] memory upperTicks, uint256[] memory weights) {
        ILiquidityStrategy strategy = ILiquidityStrategy(params.strategyAddress);

        (lowerTicks, upperTicks) = strategy.generateRanges(
            params.resolvedCenterTick, params.ticksLeft, params.ticksRight, poolKey.tickSpacing, params.useCarpet
        );

        weights = RebalanceLogic.calculateWeightsWithPoolKey(
            poolKey,
            poolManager,
            RebalanceLogic.StrategyContext({
                resolvedStrategy: params.strategyAddress,
                center: params.resolvedCenterTick,
                tLeft: params.ticksLeft,
                tRight: params.ticksRight,
                strategy: strategy,
                weight0: params.weight0,
                weight1: params.weight1,
                useCarpet: params.useCarpet,
                limitWidth: params.limitWidth,
                useAssetWeights: (params.weight0 == 0 && params.weight1 == 0)
            }),
            lowerTicks,
            upperTicks
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

    function addLimitPositionsAndCalculateInMin(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        LimitPositionsParams memory params
    )
        external
        pure
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        return SimpleLensInMinPreview.addLimitPositionsAndCalculateInMin(baseRanges, baseLiquidities, params);
    }

    function _addLimitPositionsAndCalculateInMin(
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        LimitPositionsParams memory params
    )
        internal
        pure
        returns (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        )
    {
        // Add limit positions if needed
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

            // Copy base ranges and liquidities
            for (uint256 i = 0; i < baseRanges.length; i++) {
                allRanges[i] = baseRanges[i];
                allLiquidities[i] = baseLiquidities[i];
            }

            // Calculate consumed tokens and remainders
            (uint256 remainderToken0, uint256 remainderToken1) = _calculateRemainders(
                baseRanges, baseLiquidities, params.sqrtPriceX96, params.totalAmount0, params.totalAmount1
            );

            // Add limit positions with liquidity from remainders
            allRanges[baseRanges.length] = lowerLimit;
            allRanges[baseRanges.length + 1] = upperLimit;

            // Lower limit (below current tick) gets remainder token1
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

            // Upper limit (above current tick) gets remainder token0
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

        // Calculate inMin
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
        IMultiPositionManager.Range[] memory baseRanges,
        uint128[] memory baseLiquidities,
        uint256 maxSlippageBps,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256[2][] memory inMin) {
        inMin = new uint256[2][](baseRanges.length);
        uint256 slippageMultiplier = 10000 - maxSlippageBps;

        for (uint256 i = 0; i < baseRanges.length; i++) {
            uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(baseRanges[i].lowerTick);
            uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(baseRanges[i].upperTick);

            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, baseLiquidities[i]
            );

            inMin[i] =
                [FullMath.mulDiv(amt0, slippageMultiplier, 10000), FullMath.mulDiv(amt1, slippageMultiplier, 10000)];
        }
    }
}
