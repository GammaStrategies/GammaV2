// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MultiPositionManager} from "../../MultiPositionManager.sol";
import {IMultiPositionManager} from "../../interfaces/IMultiPositionManager.sol";
import {ILiquidityStrategy} from "../../strategies/ILiquidityStrategy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SimpleLensInMin} from "./SimpleLensInMin.sol";
import {SimpleLensRatioUtilsPositions} from "./SimpleLensRatioUtilsPositions.sol";
import {DepositRatioLib} from "../DepositRatioLib.sol";
import {LiquidityAmountsCapped} from "../LiquidityAmountsCapped.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {RebalanceLogic} from "../RebalanceLogic.sol";

/**
 * @title SimpleLensRatioUtils
 * @notice Library for ratio management and initial deposit calculations for SimpleLens
 */
library SimpleLensRatioUtils {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Custom errors
    error RatioMustBeLessThanOrEqualToOne();
    error NoStrategySpecified();

    uint256 constant PRECISION = 1e18;

    struct SwapParams {
        bool swapToken0;
        uint256 swapAmount;
        uint256 weight0;
        uint256 weight1;
    }

    struct PositionStats {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        uint128 liquidity;
        uint256 token0Quantity;
        uint256 token1Quantity;
        uint256 valueInToken1;
        bool isLimit;
    }

    struct WithdrawalPreview {
        uint256 withdrawAmount;
        bool withdrawToken0;
        PositionStats[] currentPositions;
        uint256 currentTotalToken0;
        uint256 currentTotalToken1;
        PositionStats[] newPositions;
        uint256 newTotalToken0;
        uint256 newTotalToken1;
        uint256 sharesBurned;
        uint256 token0Change;
        uint256 token1Change;
    }

    struct PreviewData {
        uint256 total0;
        uint256 total1;
        uint256 totalFee0;
        uint256 totalFee1;
        uint256 unusedAmount0;
        uint256 unusedAmount1;
        uint256 availableAfterFees0;
        uint256 availableAfterFees1;
        bool needToBurnPositions;
    }

    struct PriceData {
        uint160 sqrtPriceX96;
        uint256 price;
        int24 tick;
    }

    struct DepositCalculationContext {
        IPoolManager pm;
        PoolKey poolKey;
        uint160 sqrtPriceX96;
        uint256 totalToken0InPositions;
        uint256 totalToken1InPositions;
        uint256 amount0ForPositions;
        uint256 amount1ForPositions;
    }

    // Helper struct for initial deposit parameters
    struct InitialDepositParams {
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

    // Struct for preview data
    struct RebalancePreview {
        address strategy;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        IMultiPositionManager.Range[] baseRanges;
        uint128[] liquidities;
        uint256 expectedToken0;
        uint256 expectedToken1;
    }

    struct LiquidityCalcContext {
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        uint256 totalWeightedToken0;
        uint256 totalWeightedToken1;
        uint128 totalLiquidity;
    }

    struct StrategyCallParams {
        address strategyAddress;
        int24[] lowerTicks;
        int24[] upperTicks;
        int24 currentTick;
        int24 resolvedCenterTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        int24 tickSpacing;
    }

    /**
     * @notice Calculate corresponding token amount to maintain current ratio
     * @param manager The MultiPositionManager contract
     * @param isToken0 True if user provides token0, false for token1
     * @param amount Amount of token being provided
     * @return The amount of the other token needed to maintain ratio
     */
    function getAmountsForDeposit(MultiPositionManager manager, bool isToken0, uint256 amount)
        external
        view
        returns (uint256)
    {
        (uint256 total0, uint256 total1,,) = manager.getTotalAmounts();

        if (total0 == 0 || total1 == 0) {
            return 0;
        }

        if (isToken0) {
            return FullMath.mulDiv(amount, total1, total0);
        } else {
            return FullMath.mulDiv(amount, total0, total1);
        }
    }

    /**
     * @notice Calculate which token and how much to deposit/withdraw to achieve desired ratio
     * @param manager The MultiPositionManager contract
     * @param desiredRatio The desired ratio of token0 value to total value (1e18 = 100% token0)
     * @param isDeposit True to fix ratio via deposit, false to fix via withdrawal
     * @return isToken0 True if need to deposit/withdraw token0, false for token1
     * @return amount The amount of token to deposit/withdraw
     */
    function ratioFix(MultiPositionManager manager, uint256 desiredRatio, bool isDeposit)
        external
        view
        returns (bool isToken0, uint256 amount)
    {
        if (desiredRatio > 1e18) revert RatioMustBeLessThanOrEqualToOne();

        (uint256 total0, uint256 total1,,) = manager.getTotalAmounts();

        if (total0 == 0 && total1 == 0) {
            return (true, 0);
        }

        (uint256 price, uint256 total0InToken1, uint256 totalValueInToken1, uint256 currentRatio) =
            _getPriceAndRatios(manager, total0, total1);

        if (currentRatio == desiredRatio) {
            return (true, 0);
        }

        if (isDeposit) {
            if (currentRatio < desiredRatio) {
                isToken0 = true;
                uint256 denominator = 1e18 - desiredRatio;
                if (denominator == 0) {
                    amount = type(uint256).max;
                } else {
                    uint256 targetToken0ValueInToken1 = FullMath.mulDiv(desiredRatio, totalValueInToken1, 1e18);
                    if (targetToken0ValueInToken1 > total0InToken1) {
                        uint256 neededValueInToken1 = targetToken0ValueInToken1 - total0InToken1;
                        uint256 depositValueInToken1 = FullMath.mulDiv(neededValueInToken1, 1e18, denominator);
                        amount = FullMath.mulDiv(depositValueInToken1, 1e18, price);
                    } else {
                        amount = 0;
                    }
                }
                return (isToken0, amount);
            } else {
                if (desiredRatio == 0) {
                    return (false, type(uint256).max);
                }

                uint256 targetTotalValueInToken1 = FullMath.mulDiv(total0InToken1, 1e18, desiredRatio);
                if (targetTotalValueInToken1 > totalValueInToken1) {
                    amount = targetTotalValueInToken1 - totalValueInToken1;
                } else {
                    amount = 0;
                }
                return (false, amount);
            }
        } else {
            if (currentRatio > desiredRatio) {
                uint256 denominator = 1e18 - desiredRatio;
                if (denominator == 0) {
                    return (true, total0);
                }

                uint256 targetToken0ValueInToken1 = FullMath.mulDiv(desiredRatio, totalValueInToken1, 1e18);
                if (total0InToken1 > targetToken0ValueInToken1) {
                    uint256 excessValueInToken1 = total0InToken1 - targetToken0ValueInToken1;
                    uint256 withdrawValueInToken1 = FullMath.mulDiv(excessValueInToken1, 1e18, denominator);
                    amount = FullMath.mulDiv(withdrawValueInToken1, 1e18, price);
                } else {
                    amount = 0;
                }
                return (true, amount);
            } else {
                if (desiredRatio == 0) {
                    return (true, total0);
                }

                uint256 targetTotalValueInToken1 = FullMath.mulDiv(total0InToken1, 1e18, desiredRatio);
                if (totalValueInToken1 > targetTotalValueInToken1) {
                    amount = totalValueInToken1 - targetTotalValueInToken1;
                } else {
                    amount = 0;
                }
                return (false, amount);
            }
        }
    }

    function _getPriceAndRatios(MultiPositionManager manager, uint256 total0, uint256 total1)
        private
        view
        returns (uint256 price, uint256 total0InToken1, uint256 totalValueInToken1, uint256 currentRatio)
    {
        PoolKey memory poolKey = manager.poolKey();
        IPoolManager poolManager = manager.poolManager();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        price = FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 2 ** 192);

        total0InToken1 = FullMath.mulDiv(total0, price, 1e18);
        totalValueInToken1 = total0InToken1 + total1;

        currentRatio = totalValueInToken1 > 0 ? FullMath.mulDiv(total0InToken1, 1e18, totalValueInToken1) : 0;
    }

    /**
     * @notice Calculate deposit amounts for initial position - uses externally generated ranges
     * @param ranges The ranges to use
     * @param poolKey The PoolKey for the Uniswap V4 pool
     * @param poolManager The PoolManager instance
     * @param params Parameters for the initial deposit calculation
     * @return otherAmount The amount of the other token needed
     * @return weights The density weights for each range
     * @return sqrtPriceX96 The current sqrtPrice
     * @return resolvedCenterTick The resolved center tick
     */
    function calculateInitialDepositAmounts(
        IMultiPositionManager.Range[] memory ranges,
        PoolKey memory poolKey,
        IPoolManager poolManager,
        InitialDepositParams calldata params
    )
        external
        view
        returns (uint256 otherAmount, uint256[] memory weights, uint160 sqrtPriceX96, int24 resolvedCenterTick)
    {
        int24 currentTick;
        uint256 totalWeightedToken0;
        uint256 totalWeightedToken1;

        (totalWeightedToken0, totalWeightedToken1, resolvedCenterTick, sqrtPriceX96, currentTick, weights) =
            _calculateWeightedTokenRequirements(poolKey, poolManager, ranges, params);

        if (totalWeightedToken0 == 0 && totalWeightedToken1 == 0) {
            revert("No liquidity would be added");
        }

        if (params.isToken0) {
            if (totalWeightedToken0 == 0) {
                otherAmount = 0;
            } else {
                otherAmount = FullMath.mulDiv(params.amount, totalWeightedToken1, totalWeightedToken0);
            }
        } else {
            if (totalWeightedToken1 == 0) {
                otherAmount = 0;
            } else {
                otherAmount = FullMath.mulDiv(params.amount, totalWeightedToken0, totalWeightedToken1);
            }
        }
    }

    function _calculateWeightedTokenRequirements(
        PoolKey memory poolKey,
        IPoolManager poolManager,
        IMultiPositionManager.Range[] memory ranges,
        InitialDepositParams calldata params
    )
        private
        view
        returns (
            uint256 totalWeightedToken0,
            uint256 totalWeightedToken1,
            int24 resolvedCenterTick,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint256[] memory weights
        )
    {
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
        resolvedCenterTick =
            RebalanceLogic.resolveAndClampCenterTick(params.centerTick, currentTick, poolKey.tickSpacing);

        // Get density weights from strategy
        weights = _callStrategyForWeights(ranges, params, resolvedCenterTick, currentTick, poolKey.tickSpacing);

        // Calculate weighted token requirements
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick != 0 || ranges[i].upperTick != 0) {
                uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
                uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

                (uint256 amount0For1e18, uint256 amount1For1e18) =
                    LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, 1e18);

                totalWeightedToken0 += (amount0For1e18 * weights[i]) / 1e18;
                totalWeightedToken1 += (amount1For1e18 * weights[i]) / 1e18;
            }
        }
    }

    function _calculateInitialLiquiditiesPublic(
        IMultiPositionManager.Range[] memory ranges,
        uint256 depositToken0,
        uint256 depositToken1,
        uint160 sqrtPriceX96,
        uint256[] memory weights
    ) internal pure returns (uint128[] memory) {
        return _calculateInitialLiquidities(ranges, depositToken0, depositToken1, sqrtPriceX96, weights);
    }

    function _calculateInitialLiquidities(
        IMultiPositionManager.Range[] memory ranges,
        uint256 depositToken0,
        uint256 depositToken1,
        uint160 sqrtPriceX96,
        uint256[] memory weights
    ) private pure returns (uint128[] memory) {
        uint128[] memory liquidities = new uint128[](ranges.length);

        if (ranges.length == 0 || weights.length == 0) return liquidities;

        LiquidityCalcContext memory ctx;

        // First pass: calculate weighted requirements
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick != 0 || ranges[i].upperTick != 0) {
                ctx.sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
                ctx.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

                (uint256 amount0For1e18, uint256 amount1For1e18) =
                    LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, ctx.sqrtPriceLower, ctx.sqrtPriceUpper, 1e18);

                ctx.totalWeightedToken0 += (amount0For1e18 * weights[i]) / 1e18;
                ctx.totalWeightedToken1 += (amount1For1e18 * weights[i]) / 1e18;
            }
        }

        if (ctx.totalWeightedToken0 == 0 && ctx.totalWeightedToken1 == 0) return liquidities;

        // Calculate maximum liquidity
        {
            uint128 maxLiquidityFromToken0 = ctx.totalWeightedToken0 > 0
                ? uint128((depositToken0 * 1e18) / ctx.totalWeightedToken0)
                : type(uint128).max;
            uint128 maxLiquidityFromToken1 = ctx.totalWeightedToken1 > 0
                ? uint128((depositToken1 * 1e18) / ctx.totalWeightedToken1)
                : type(uint128).max;

            ctx.totalLiquidity =
                maxLiquidityFromToken0 < maxLiquidityFromToken1 ? maxLiquidityFromToken0 : maxLiquidityFromToken1;
        }

        // Second pass: distribute liquidity
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick != 0 || ranges[i].upperTick != 0) {
                uint128 targetLiquidity = uint128((uint256(ctx.totalLiquidity) * weights[i]) / 1e18);

                {
                    ctx.sqrtPriceLower = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
                    ctx.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

                    (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                        sqrtPriceX96, ctx.sqrtPriceLower, ctx.sqrtPriceUpper, targetLiquidity
                    );

                    liquidities[i] = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
                        sqrtPriceX96, ctx.sqrtPriceLower, ctx.sqrtPriceUpper, amount0, amount1
                    );
                }
            }
        }

        return liquidities;
    }

    function _callStrategyForWeights(
        IMultiPositionManager.Range[] memory ranges,
        InitialDepositParams calldata params,
        int24 resolvedCenterTick,
        int24 currentTick,
        int24 tickSpacing
    ) private view returns (uint256[] memory) {
        (int24[] memory lowerTicks, int24[] memory upperTicks) = _extractTickArrays(ranges);

        StrategyCallParams memory callParams = StrategyCallParams({
            strategyAddress: params.strategyAddress,
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            currentTick: currentTick,
            resolvedCenterTick: resolvedCenterTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            tickSpacing: tickSpacing
        });

        return _executeStrategyCall(callParams);
    }

    function _extractTickArrays(IMultiPositionManager.Range[] memory ranges)
        private
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        lowerTicks = new int24[](ranges.length);
        upperTicks = new int24[](ranges.length);

        for (uint256 i = 0; i < ranges.length; i++) {
            lowerTicks[i] = ranges[i].lowerTick;
            upperTicks[i] = ranges[i].upperTick;
        }
    }

    function _executeStrategyCall(StrategyCallParams memory callParams) private view returns (uint256[] memory) {
        bool useAssetWeights = (callParams.weight0 == 0 && callParams.weight1 == 0);
        return _executeStrategyCallWithAssetFlag(callParams, useAssetWeights);
    }

    function _executeStrategyCallWithAssetFlag(StrategyCallParams memory callParams, bool useAssetWeights)
        private
        view
        returns (uint256[] memory)
    {
        bytes memory callData = abi.encodeCall(
            ILiquidityStrategy.calculateDensities,
            (
                callParams.lowerTicks,
                callParams.upperTicks,
                callParams.currentTick,
                callParams.resolvedCenterTick,
                callParams.ticksLeft,
                callParams.ticksRight,
                callParams.weight0,
                callParams.weight1,
                callParams.useCarpet,
                callParams.tickSpacing,
                useAssetWeights
            )
        );

        (bool success, bytes memory returnData) = callParams.strategyAddress.staticcall(callData);

        if (!success) revert("CalculateDensitiesFailed");
        uint256[] memory weights = abi.decode(returnData, (uint256[]));
        return RebalanceLogic.adjustWeightsForFullRangeFloor(
            weights, callParams.lowerTicks, callParams.upperTicks, callParams.tickSpacing, callParams.useCarpet
        );
    }

    function getMaxWithdrawable(MultiPositionManager manager)
        internal
        view
        returns (uint256 maxToken0, uint256 maxToken1)
    {
        (uint256 total0, uint256 total1,,) = manager.getTotalAmounts();

        (,,,,,,,, bool carpetEnabled,) = manager.lastStrategyParams();

        if (!carpetEnabled) {
            return (total0, total1);
        }

        uint256 reserved0;
        uint256 reserved1;

        {
            PoolKey memory poolKey = manager.poolKey();
            int24 minUsable = TickMath.minUsableTick(poolKey.tickSpacing);
            int24 maxUsable = TickMath.maxUsableTick(poolKey.tickSpacing);

            (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
                manager.getPositions();

            uint256 carpetToken0 = 0;
            uint256 carpetToken1 = 0;

            for (uint256 i = 0; i < ranges.length; i++) {
                if (ranges[i].lowerTick == minUsable && ranges[i].upperTick == maxUsable) {
                    carpetToken0 += positionData[i].amount0;
                    carpetToken1 += positionData[i].amount1;
                }
            }

            reserved0 = carpetToken0 + 1;
            reserved1 = carpetToken1 + 1;
        }

        maxToken0 = total0 > reserved0 ? total0 - reserved0 : 0;
        maxToken1 = total1 > reserved1 ? total1 - reserved1 : 0;
    }

    function calculateDirectDepositInMin(
        MultiPositionManager manager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 maxSlippage,
        uint256, /* basePositionsLength */
        uint256[2][] memory inMin
    ) internal view returns (uint256[2][] memory) {
        // Get positions data
        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        // Get total tokens in positions (including both base and limit positions)
        uint256 totalToken0InPositions;
        uint256 totalToken1InPositions;

        for (uint256 i = 0; i < ranges.length; i++) {
            if (positionData[i].liquidity == 0) continue;
            totalToken0InPositions += positionData[i].amount0;
            totalToken1InPositions += positionData[i].amount1;
        }

        // Calculate what CAN go into positions
        uint256 amount0ForPositions;
        uint256 amount1ForPositions;

        if (totalToken0InPositions == 0 && totalToken1InPositions > 0) {
            amount0ForPositions = 0;
            amount1ForPositions = amount1Desired;
        } else if (totalToken1InPositions == 0 && totalToken0InPositions > 0) {
            amount0ForPositions = amount0Desired;
            amount1ForPositions = 0;
        } else if (totalToken0InPositions > 0 && totalToken1InPositions > 0) {
            (amount0ForPositions, amount1ForPositions) = DepositRatioLib.getRatioAmounts(
                totalToken0InPositions, totalToken1InPositions, amount0Desired, amount1Desired
            );
        }

        // Apply slippage and distribute to all positions (base and limit)
        uint256 slippageFactor = (10000 - maxSlippage);

        for (uint256 i = 0; i < ranges.length; i++) {
            if (positionData[i].liquidity == 0) continue;

            // Calculate share based on current token amounts (round down for conservative minimums)
            if (totalToken0InPositions > 0) {
                uint256 amount0ForPosition =
                    FullMath.mulDiv(amount0ForPositions, positionData[i].amount0, totalToken0InPositions);
                inMin[i][0] = FullMath.mulDiv(amount0ForPosition, slippageFactor, 10000);
            }

            if (totalToken1InPositions > 0) {
                uint256 amount1ForPosition =
                    FullMath.mulDiv(amount1ForPositions, positionData[i].amount1, totalToken1InPositions);
                inMin[i][1] = FullMath.mulDiv(amount1ForPosition, slippageFactor, 10000);
            }
        }

        return inMin;
    }

    struct CompoundSwapContext {
        uint256 totalFee0;
        uint256 totalFee1;
        uint256 idle0;
        uint256 idle1;
        uint256 totalAvailable0;
        uint256 totalAvailable1;
    }

    /**
     * @notice Calculate minimum input amounts for compound with slippage protection
     * @dev Factors in: fees (from zeroBurn) + idle vault balance + deposit amounts
     * @param manager MultiPositionManager address
     * @param deposit0 Amount of token0 being deposited (can be 0)
     * @param deposit1 Amount of token1 being deposited (can be 0)
     * @param needsSwap Whether to calculate optimal swap
     * @param maxSlippageBps Maximum slippage in basis points (10000 = 100%)
     * @return inMin Array of minimum amounts for each base and limit position
     * @return swapToken0 True if should swap token0→token1, false for token1→token0
     * @return swapAmount How much to swap (in tokenIn)
     */
    function getInMinForCompound(
        MultiPositionManager manager,
        uint256 deposit0,
        uint256 deposit1,
        bool needsSwap,
        uint256 maxSlippageBps
    ) external view returns (uint256[2][] memory inMin, bool swapToken0, uint256 swapAmount) {
        uint256 basePositionsLength = manager.basePositionsLength();
        if (basePositionsLength == 0) {
            return (inMin, false, 0);
        }

        // Calculate final amounts with optional swap
        uint256 finalAmount0;
        uint256 finalAmount1;
        (finalAmount0, finalAmount1, swapToken0, swapAmount,,) =
            _getCompoundSwapAmounts(manager, deposit0, deposit1, needsSwap);

        // Calculate inMin
        inMin = _getCompoundInMin(manager, finalAmount0, finalAmount1, maxSlippageBps);
        return (inMin, swapToken0, swapAmount);
    }

    /**
     * @notice Calculate amounts and preview positions for compound with optional deposit and swap
     * @dev Works for all scenarios: fee compound only, deposit+compound, with/without optimal swap
     *      Factors in: fees (from zeroBurn) + idle vault balance + deposit amounts
     * @param manager MultiPositionManager address
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
        MultiPositionManager manager,
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
            SwapParams memory swapParams,
            uint256[2][] memory inMin,
            PositionStats[] memory expectedPositions
        )
    {
        if (manager.basePositionsLength() == 0) {
            return (0, 0, SwapParams(false, 0, 0, 0), inMin, expectedPositions);
        }

        // Calculate final amounts and swap params in scoped block
        {
            bool swapToken0;
            uint256 swapAmount;
            uint256 weight0;
            uint256 weight1;
            (finalAmount0, finalAmount1, swapToken0, swapAmount, weight0, weight1) =
                _getCompoundSwapAmounts(manager, deposit0, deposit1, needsSwap);

            // Construct swap parameters struct
            swapParams =
                SwapParams({swapToken0: swapToken0, swapAmount: swapAmount, weight0: weight0, weight1: weight1});
        }

        // Calculate inMin
        inMin = _getCompoundInMin(manager, finalAmount0, finalAmount1, maxSlippageBps);

        // Calculate expected positions in scoped block
        {
            (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
                manager.getPositions();

            expectedPositions =
                calculateExpectedPositionsAfterDeposit(manager, ranges, positionData, finalAmount0, finalAmount1);
        }
    }

    function _getCompoundSwapAmounts(MultiPositionManager manager, uint256 deposit0, uint256 deposit1, bool needsSwap)
        private
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            bool swapToken0,
            uint256 swapAmount,
            uint256 weight0,
            uint256 weight1
        )
    {
        // Calculate total available
        (uint256 totalAvailable0, uint256 totalAvailable1) = _calculateTotalAvailable(manager, deposit0, deposit1);

        if (!needsSwap) {
            return (totalAvailable0, totalAvailable1, false, 0, 0, 0);
        }

        // Get price and weights in nested scope
        uint160 sqrtPriceX96;
        {
            PoolKey memory poolKey = manager.poolKey();
            IPoolManager pm = manager.poolManager();
            (sqrtPriceX96,,,) = pm.getSlot0(poolKey.toId());
            (weight0, weight1) = calculateWeightsFromPositions(manager, sqrtPriceX96);
        }

        // Calculate and apply swap
        (swapToken0, swapAmount) =
            _calculateOptimalSwap(totalAvailable0, totalAvailable1, sqrtPriceX96, weight0, weight1);

        (finalAmount0, finalAmount1) = applySwap(totalAvailable0, totalAvailable1, swapToken0, swapAmount, sqrtPriceX96);
    }

    function _calculateTotalAvailable(MultiPositionManager manager, uint256 deposit0, uint256 deposit1)
        private
        view
        returns (uint256 totalAvailable0, uint256 totalAvailable1)
    {
        (,, uint256 totalFee0, uint256 totalFee1) = manager.getTotalAmounts();

        PoolKey memory poolKey = manager.poolKey();
        uint256 idle0 = Currency.unwrap(poolKey.currency0) == address(0)
            ? address(manager).balance
            : IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(manager));
        uint256 idle1 = Currency.unwrap(poolKey.currency1) == address(0)
            ? address(manager).balance
            : IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(manager));

        totalAvailable0 = totalFee0 + idle0 + deposit0;
        totalAvailable1 = totalFee1 + idle1 + deposit1;
    }

    function _getCompoundInMin(
        MultiPositionManager manager,
        uint256 finalAmount0,
        uint256 finalAmount1,
        uint256 maxSlippageBps
    ) private view returns (uint256[2][] memory inMin) {
        uint256 basePositionsLength = manager.basePositionsLength();
        uint256 limitPositionsLength = manager.limitPositionsLength();
        inMin = new uint256[2][](basePositionsLength + limitPositionsLength);

        return
            calculateDirectDepositInMin(manager, finalAmount0, finalAmount1, maxSlippageBps, basePositionsLength, inMin);
    }

    /**
     * @notice Calculate weights from existing positions
     * @dev Uses current position composition to determine target weights
     * @param manager The MultiPositionManager
     * @param sqrtPriceX96 Current pool price
     * @return weight0 Weight for token0
     * @return weight1 Weight for token1
     */
    function calculateWeightsFromPositions(MultiPositionManager manager, uint160 sqrtPriceX96)
        public
        view
        returns (uint256 weight0, uint256 weight1)
    {
        // Get total amounts in positions (excluding fees)
        (uint256 total0, uint256 total1,,) = manager.getTotalAmounts();

        // Calculate value in token1 terms for weight calculation
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        uint256 value0InToken1 = FullMath.mulDiv(total0, price, PRECISION);
        uint256 totalValue = value0InToken1 + total1;

        if (totalValue == 0) {
            // No positions, use 50/50
            weight0 = PRECISION / 2;
            weight1 = PRECISION / 2;
        } else {
            // Calculate weights based on current composition
            weight0 = FullMath.mulDiv(value0InToken1, PRECISION, totalValue);
            weight1 = FullMath.mulDiv(total1, PRECISION, totalValue);
        }
    }

    /**
     * @notice Apply swap simulation to calculate final amounts
     * @param amount0 Initial amount of token0
     * @param amount1 Initial amount of token1
     * @param swapToken0 True if swapping token0 for token1
     * @param swapAmount Amount to swap
     * @param sqrtPriceX96 Current sqrt price
     * @return finalAmount0 Amount of token0 after swap
     * @return finalAmount1 Amount of token1 after swap
     */
    function applySwap(uint256 amount0, uint256 amount1, bool swapToken0, uint256 swapAmount, uint160 sqrtPriceX96)
        public
        pure
        returns (uint256 finalAmount0, uint256 finalAmount1)
    {
        if (swapAmount == 0) {
            return (amount0, amount1);
        }

        if (swapToken0) {
            uint256 estimatedOut = FullMath.mulDiv(
                FullMath.mulDiv(swapAmount, uint256(sqrtPriceX96), 1 << 96), uint256(sqrtPriceX96), 1 << 96
            );
            finalAmount0 = amount0 - swapAmount;
            finalAmount1 = amount1 + estimatedOut;
        } else {
            uint256 estimatedOut = FullMath.mulDiv(
                FullMath.mulDiv(swapAmount, 1 << 96, uint256(sqrtPriceX96)), 1 << 96, uint256(sqrtPriceX96)
            );
            finalAmount0 = amount0 + estimatedOut;
            finalAmount1 = amount1 - swapAmount;
        }
    }

    /**
     * @notice Calculate optimal swap for rebalancing (uses RebalanceLogic)
     * @dev This is a thin wrapper around RebalanceLogic.calculateOptimalSwap
     */
    function _calculateOptimalSwap(
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 weight0,
        uint256 weight1
    ) private pure returns (bool swapToken0, uint256 swapAmount) {
        return RebalanceLogic.calculateOptimalSwap(amount0, amount1, sqrtPriceX96, weight0, weight1);
    }

    /**
     * @notice Preview expected position states after deposit
     * @dev Already exists in library - this function calculates expected positions after deposit
     */
    function calculateExpectedPositionsAfterDeposit(
        MultiPositionManager manager,
        IMultiPositionManager.Range[] memory ranges,
        IMultiPositionManager.PositionData[] memory positionData,
        uint256 deposit0,
        uint256 deposit1
    ) public view returns (PositionStats[] memory expectedPositions) {
        return SimpleLensRatioUtilsPositions.calculateExpectedPositionsAfterDeposit(
            manager, ranges, positionData, deposit0, deposit1
        );
    }

    /**
     * @notice Get position statistics for all positions in a manager
     * @param manager The MultiPositionManager to query
     * @return stats Array of PositionStats for each position
     */
    function getPositionStats(MultiPositionManager manager) external view returns (PositionStats[] memory stats) {
        return SimpleLensRatioUtilsPositions.getPositionStats(manager);
    }

    /**
     * @notice Calculate optimal swap parameters for rebalancing
     * @param manager The MultiPositionManager
     * @param strategy Address of liquidity strategy
     * @param centerTick Center tick for new positions
     * @param ticksLeft Number of ticks left of center
     * @param ticksRight Number of ticks right of center
     * @param weight0 Weight for token0 (0 for calculate from strategy)
     * @param weight1 Weight for token1 (0 for calculate from strategy)
     * @param useCarpet Whether to use the full-range floor
     * @param poolManager The pool manager instance
     * @param amount0 Pre-computed amount of token0 (allows caller to deduct fees if needed)
     * @param amount1 Pre-computed amount of token1 (allows caller to deduct fees if needed)
     * @return swapParams Calculated swap parameters
     */
    function calculateOptimalSwapForRebalance(
        MultiPositionManager manager,
        address strategy,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        uint256 weight0,
        uint256 weight1,
        bool useCarpet,
        IPoolManager poolManager,
        uint256 amount0,
        uint256 amount1
    ) external view returns (SwapParams memory swapParams) {

        // Get current pool state
        PoolKey memory poolKey = manager.poolKey();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Resolve center tick exactly like on-chain rebalance (floor-snap + clamp).
        int24 resolvedCenter =
            RebalanceLogic.resolveAndClampCenterTick(centerTick, currentTick, poolKey.tickSpacing);

        // Use provided weights OR calculate from strategy
        if (weight0 == 0 && weight1 == 0) {
            (swapParams.weight0, swapParams.weight1) = RebalanceLogic.calculateWeightsFromStrategy(
                ILiquidityStrategy(strategy),
                resolvedCenter,
                ticksLeft,
                ticksRight,
                poolKey.tickSpacing,
                useCarpet,
                sqrtPriceX96,
                currentTick
            );
        } else {
            swapParams.weight0 = weight0;
            swapParams.weight1 = weight1;
        }

        // Calculate optimal swap
        (swapParams.swapToken0, swapParams.swapAmount) =
            RebalanceLogic.calculateOptimalSwap(amount0, amount1, sqrtPriceX96, swapParams.weight0, swapParams.weight1);
    }

    /**
     * @notice Extract weights from strategy for given ranges
     */
    function extractWeightsFromStrategy(
        IMultiPositionManager.Range[] memory ranges,
        address strategyAddr,
        uint24 tLeft,
        uint24 tRight,
        bool useCarpet,
        uint256 w0,
        uint256 w1,
        int24 currentTick,
        int24 resolvedCenter,
        int24 spacing
    ) external view returns (uint256[] memory weights) {
        // Extract ticks
        (int24[] memory lowerTicks, int24[] memory upperTicks) = _extractTicks(ranges);

        StrategyCallParams memory callParams = StrategyCallParams({
            strategyAddress: strategyAddr,
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            currentTick: currentTick,
            resolvedCenterTick: resolvedCenter,
            ticksLeft: tLeft,
            ticksRight: tRight,
            weight0: w0,
            weight1: w1,
            useCarpet: useCarpet,
            tickSpacing: spacing
        });
        return _executeStrategyCallWithAssetFlag(callParams, false);
    }

    function _extractTicks(IMultiPositionManager.Range[] memory ranges)
        private
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        uint256 len = ranges.length;
        lowerTicks = new int24[](len);
        upperTicks = new int24[](len);
        for (uint256 i = 0; i < len; i++) {
            lowerTicks[i] = ranges[i].lowerTick;
            upperTicks[i] = ranges[i].upperTick;
        }
    }

    struct DensityParams {
        int24 currentTick;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        int24 tickSpacing;
    }

    /**
     * @notice Get ranges and weights from strategy
     */
    function getRangesAndWeights(
        MultiPositionManager manager,
        address strategyAddress,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        uint256 weight0,
        uint256 weight1,
        bool useCarpet
    )
        external
        view
        returns (int24[] memory lowerTicks, int24[] memory upperTicks, uint256[] memory weights, uint160 sqrtPriceX96)
    {
        PoolKey memory poolKey = manager.poolKey();

        // Generate ranges
        (lowerTicks, upperTicks) = ILiquidityStrategy(strategyAddress).generateRanges(
            centerTick, ticksLeft, ticksRight, poolKey.tickSpacing, useCarpet
        );

        // Get price
        int24 currentTick;
        {
            IPoolManager pm = manager.poolManager();
            (sqrtPriceX96, currentTick,,) = pm.getSlot0(poolKey.toId());
        }

        // Bundle params and calculate
        DensityParams memory params = DensityParams({
            currentTick: currentTick,
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            weight0: weight0,
            weight1: weight1,
            useCarpet: useCarpet,
            tickSpacing: poolKey.tickSpacing
        });

        weights = ILiquidityStrategy(strategyAddress).calculateDensities(
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
            params.weight0 == 0 && params.weight1 == 0
        );
        weights = RebalanceLogic.adjustWeightsForFullRangeFloor(
            weights, lowerTicks, upperTicks, params.tickSpacing, params.useCarpet
        );
    }

    /**
     * @notice Generate ranges from strategy
     */
    function generateRangesFromStrategy(
        MultiPositionManager manager,
        address strategyAddress,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        bool useCarpet
    ) external view returns (IMultiPositionManager.Range[] memory baseRanges) {
        // Get pool key for tick spacing
        PoolKey memory poolKey = manager.poolKey();
        int24 tickSpacing = poolKey.tickSpacing;

        IPoolManager pm = manager.poolManager();
        (, int24 currentTick,,) = pm.getSlot0(poolKey.toId());
        centerTick = RebalanceLogic.resolveAndClampCenterTick(centerTick, currentTick, tickSpacing);

        // Generate ranges from strategy
        if (strategyAddress == address(0)) revert("No strategy specified");
        ILiquidityStrategy strategy = ILiquidityStrategy(strategyAddress);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);

        // Convert to Range array
        baseRanges = new IMultiPositionManager.Range[](lowerTicks.length);
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            baseRanges[i] = IMultiPositionManager.Range(lowerTicks[i], upperTicks[i]);
        }
    }

    /**
     * @notice Build position stats for deposit preview
     */

    /**
     * @notice Calculate limit order ranges
     */
    function calculateLimitRanges(
        MultiPositionManager manager,
        uint24 limitWidth,
        IMultiPositionManager.Range[] memory baseRanges,
        uint24, /* ticksLeft */
        uint24 /* ticksRight */
    )
        external
        view
        returns (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit)
    {
        PoolKey memory poolKey = manager.poolKey();
        int24 tickSpacing = poolKey.tickSpacing;

        // Adjust limitWidth to be a multiple of tickSpacing
        if (int24(limitWidth) % tickSpacing != 0) {
            limitWidth = uint24((int24(limitWidth) / tickSpacing + 1) * tickSpacing);
        }

        // Simple check: if limitWidth equals any base range width, adjust it
        for (uint256 i = 0; i < baseRanges.length; i++) {
            int24 rangeWidth = baseRanges[i].upperTick - baseRanges[i].lowerTick;
            if (rangeWidth == int24(limitWidth)) {
                limitWidth = uint24(int24(limitWidth) + tickSpacing);
                break;
            }
        }

        // Get current tick
        IPoolManager pm = manager.poolManager();
        (, int24 tick,,) = pm.getSlot0(poolKey.toId());
        int24 baseTick;

        // Align baseTick with tick spacing
        if (tick % tickSpacing == 0) {
            baseTick = tick;
        } else if (tick % tickSpacing > 0) {
            baseTick = (tick / tickSpacing) * tickSpacing;
        } else {
            baseTick = ((tick - tickSpacing + 1) / tickSpacing) * tickSpacing;
        }

        // Calculate limit positions
        lowerLimit.lowerTick = roundToTickSpacing(baseTick - int24(limitWidth), tickSpacing, true);
        lowerLimit.upperTick = roundToTickSpacing(baseTick, tickSpacing, false);

        upperLimit.lowerTick = roundToTickSpacing(baseTick + tickSpacing, tickSpacing, true);
        upperLimit.upperTick = roundToTickSpacing(baseTick + tickSpacing + int24(limitWidth), tickSpacing, false);

        // Ensure within usable tick range
        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        if (lowerLimit.lowerTick < minUsableTick) lowerLimit.lowerTick = minUsableTick;
        if (lowerLimit.upperTick > maxUsableTick) lowerLimit.upperTick = maxUsableTick;
        if (upperLimit.lowerTick < minUsableTick) upperLimit.lowerTick = minUsableTick;
        if (upperLimit.upperTick > maxUsableTick) upperLimit.upperTick = maxUsableTick;
    }

    function roundToTickSpacing(int24 tick, int24 tickSpacing, bool roundDown) public pure returns (int24) {
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) return tick;

        if (roundDown) {
            return
                tick < 0 ? ((tick - tickSpacing + 1) / tickSpacing) * tickSpacing : (tick / tickSpacing) * tickSpacing;
        } else {
            return
                tick < 0 ? (tick / tickSpacing) * tickSpacing : ((tick + tickSpacing - 1) / tickSpacing) * tickSpacing;
        }
    }

    /**
     * @notice Simulate swap for rebalancing
     */
    function simulateSwapForRebalance(
        MultiPositionManager manager,
        uint256 amount0,
        uint256 amount1,
        uint256 weight0,
        uint256 weight1
    ) external view returns (uint256 newAmount0, uint256 newAmount1) {
        IPoolManager pm = manager.poolManager();
        PoolKey memory poolKey = manager.poolKey();

        (uint160 sqrtPriceX96ForSwap,,,) = pm.getSlot0(poolKey.toId());

        (bool swapToken0, uint256 swapAmount) =
            RebalanceLogic.calculateOptimalSwap(amount0, amount1, sqrtPriceX96ForSwap, weight0, weight1);

        newAmount0 = amount0;
        newAmount1 = amount1;

        if (swapAmount > 0) {
            if (swapToken0) {
                uint256 amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(swapAmount, uint256(sqrtPriceX96ForSwap), 1 << 96),
                    uint256(sqrtPriceX96ForSwap),
                    1 << 96
                );
                newAmount0 -= swapAmount;
                newAmount1 += amountOut;
            } else {
                uint256 amountOut = FullMath.mulDiv(
                    FullMath.mulDiv(swapAmount, 1 << 96, uint256(sqrtPriceX96ForSwap)),
                    1 << 96,
                    uint256(sqrtPriceX96ForSwap)
                );
                newAmount1 -= swapAmount;
                newAmount0 += amountOut;
            }
        }
    }

    /**
     * @notice Get weights for strategy with given ticks
     */
    function getWeightsForStrategy(
        address strategyAddress,
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        int24 currentTick,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        uint256 weight0,
        uint256 weight1,
        bool useCarpet,
        int24 tickSpacing
    ) external view returns (uint256[] memory) {
        DensityParams memory params = DensityParams({
            currentTick: currentTick,
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            weight0: weight0,
            weight1: weight1,
            useCarpet: useCarpet,
            tickSpacing: tickSpacing
        });

        uint256[] memory weights = ILiquidityStrategy(strategyAddress).calculateDensities(
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
            params.weight0 == 0 && params.weight1 == 0
        );
        return RebalanceLogic.adjustWeightsForFullRangeFloor(
            weights, lowerTicks, upperTicks, params.tickSpacing, params.useCarpet
        );
    }

    /**
     * @notice Calculate limit order ranges with PoolKey
     */
    function calculateLimitRangesWithPoolKey(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint24 limitWidth,
        IMultiPositionManager.Range[] memory, /* baseRanges */
        uint24 ticksLeft,
        uint24 ticksRight
    )
        external
        view
        returns (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit)
    {
        int24 tickSpacing = poolKey.tickSpacing;
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());

        // Calculate the outer boundary ticks
        int24 leftBoundary = currentTick - int24(ticksLeft);
        int24 rightBoundary = currentTick + int24(ticksRight);

        // Lower limit position (below current price)
        lowerLimit.upperTick = leftBoundary;
        lowerLimit.lowerTick = leftBoundary - int24(limitWidth);

        // Upper limit position (above current price)
        upperLimit.lowerTick = rightBoundary;
        upperLimit.upperTick = rightBoundary + int24(limitWidth);

        // Round to tick spacing
        lowerLimit.lowerTick = roundToTickSpacing(lowerLimit.lowerTick, tickSpacing, true);
        lowerLimit.upperTick = roundToTickSpacing(lowerLimit.upperTick, tickSpacing, false);
        upperLimit.lowerTick = roundToTickSpacing(upperLimit.lowerTick, tickSpacing, true);
        upperLimit.upperTick = roundToTickSpacing(upperLimit.upperTick, tickSpacing, false);

        // Ensure within usable tick range
        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        if (lowerLimit.lowerTick < minUsableTick) lowerLimit.lowerTick = minUsableTick;
        if (lowerLimit.upperTick > maxUsableTick) lowerLimit.upperTick = maxUsableTick;
        if (upperLimit.lowerTick < minUsableTick) upperLimit.lowerTick = minUsableTick;
        if (upperLimit.upperTick > maxUsableTick) upperLimit.upperTick = maxUsableTick;
    }

    /**
     * @notice Generate ranges from strategy with PoolKey
     */
    function generateRangesFromStrategyWithPoolKey(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        address strategyAddress,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        bool useCarpet
    ) external view returns (IMultiPositionManager.Range[] memory baseRanges) {
        int24 tickSpacing = poolKey.tickSpacing;

        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        centerTick = RebalanceLogic.resolveAndClampCenterTick(centerTick, currentTick, tickSpacing);

        // Generate ranges from strategy
        if (strategyAddress == address(0)) revert NoStrategySpecified();
        ILiquidityStrategy strategy = ILiquidityStrategy(strategyAddress);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);

        // Convert to Range array
        baseRanges = new IMultiPositionManager.Range[](lowerTicks.length);
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            baseRanges[i] = IMultiPositionManager.Range(lowerTicks[i], upperTicks[i]);
        }
    }
}
