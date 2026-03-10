// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SimpleLensInMin} from "../libraries/SimpleLens/SimpleLensInMin.sol";
import {SimpleLensRatioUtils} from "../libraries/SimpleLens/SimpleLensRatioUtils.sol";
import {InitialDepositLensLogic} from "../libraries/InitialDepositLensLogic.sol";

/**
 * @title InitialDepositLens
 * @notice Read-only contract for previewing initial deposits to UNINITIALIZED pools
 * @dev For uninitialized pools, sqrtPriceX96 must be provided as a parameter since getSlot0() returns default values.
 *      For initialized pools, use SimpleLens.sol instead.
 */
contract InitialDepositLens {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Immutable storage
    IPoolManager public immutable poolManager;

    // Custom errors
    error NoStrategySpecified();
    error MaxSlippageExceeded();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // Use structs from SimpleLens to avoid duplication
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

    struct CustomInitialDepositParams {
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

    /**
     * @notice Calculate deposit amounts for initial position and preview the rebalance
     * @dev FOR INITIALIZED POOLS - fetches sqrtPriceX96 from getSlot0()
     * @param poolKey The PoolKey for the Uniswap V4 pool
     * @param params Parameters for the initial deposit calculation
     * @return otherAmount The amount of the other token needed
     * @return inMin The minimum amounts for each position (for slippage protection)
     * @return preview Detailed preview of the rebalance operation
     */
    function getAmountsForInitialDepositAndPreviewRebalance(
        PoolKey memory poolKey,
        InitialDepositParams calldata params
    )
        external
        view
        returns (uint256 otherAmount, uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview)
    {
        // Fetch sqrtPriceX96 from initialized pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        return getAmountsForInitialDepositAndPreviewRebalance(poolKey, sqrtPriceX96, params);
    }

    /**
     * @notice Calculate deposit amounts for initial position and preview the rebalance
     * @dev FOR UNINITIALIZED POOLS ONLY - sqrtPriceX96 is provided since pool hasn't been initialized yet
     * @param poolKey The PoolKey for the Uniswap V4 pool
     * @param sqrtPriceX96 The intended sqrtPriceX96 for pool initialization
     * @param params Parameters for the initial deposit calculation
     * @return otherAmount The amount of the other token needed
     * @return inMin The minimum amounts for each position (for slippage protection)
     * @return preview Detailed preview of the rebalance operation
     */
    function getAmountsForInitialDepositAndPreviewRebalance(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        InitialDepositParams calldata params
    )
        public
        view
        returns (uint256 otherAmount, uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview)
    {
        InitialDepositLensLogic.DepositParams memory lensParams = InitialDepositLensLogic.DepositParams({
            strategyAddress: params.strategyAddress,
            centerTick: params.centerTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            isToken0: params.isToken0,
            amount: params.amount,
            maxSlippageBps: params.maxSlippageBps
        });

        return InitialDepositLensLogic.getAmountsForInitialDepositAndPreviewRebalance(
            poolManager, poolKey, sqrtPriceX96, lensParams
        );
    }

    /**
     * @notice Preview initial deposit and rebalance with custom amounts (both token0 and token1)
     * @dev FOR INITIALIZED POOLS - fetches sqrtPriceX96 from getSlot0()
     * @param poolKey The pool key
     * @param params Custom initial deposit parameters with both deposit0 and deposit1
     * @return inMin Minimum input amounts for each base position
     * @return preview Detailed preview of the rebalance operation with actual distribution
     */
    function previewCustomInitialDepositAndRebalance(PoolKey memory poolKey, CustomInitialDepositParams calldata params)
        external
        view
        returns (uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview)
    {
        // Fetch sqrtPriceX96 from initialized pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        return previewCustomInitialDepositAndRebalance(poolKey, sqrtPriceX96, params);
    }

    /**
     * @notice Preview initial deposit and rebalance with custom amounts (both token0 and token1)
     * @dev FOR UNINITIALIZED POOLS ONLY - Similar to getAmountsForInitialDepositAndPreviewRebalance but accepts
     *      explicit deposit0 and deposit1 amounts. Use this when you want to deposit a custom ratio that differs
     *      from the balanced ratio SimpleLens would recommend.
     * @param poolKey The pool key
     * @param sqrtPriceX96 The intended sqrtPriceX96 for pool initialization
     * @param params Custom initial deposit parameters with both deposit0 and deposit1
     * @return inMin Minimum input amounts for each base position
     * @return preview Detailed preview of the rebalance operation with actual distribution
     */
    function previewCustomInitialDepositAndRebalance(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        CustomInitialDepositParams calldata params
    ) public view returns (uint256[2][] memory inMin, SimpleLensInMin.RebalancePreview memory preview) {
        InitialDepositLensLogic.CustomDepositParams memory lensParams = InitialDepositLensLogic.CustomDepositParams({
            strategyAddress: params.strategyAddress,
            centerTick: params.centerTick,
            ticksLeft: params.ticksLeft,
            ticksRight: params.ticksRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            deposit0: params.deposit0,
            deposit1: params.deposit1,
            maxSlippageBps: params.maxSlippageBps
        });

        return InitialDepositLensLogic.previewCustomInitialDepositAndRebalance(poolKey, sqrtPriceX96, lensParams);
    }

    /**
     * @notice Calculate swap needed for initial deposit with any token ratio, then preview positions
     * @dev FOR INITIALIZED POOLS - fetches sqrtPriceX96 from getSlot0()
     * @param poolKey The PoolKey for the Uniswap V4 pool
     * @param params Parameters including both token amounts (any ratio)
     * @return finalAmount0 Amount of token0 after optimal swap
     * @return finalAmount1 Amount of token1 after optimal swap
     * @return swapParams Swap details (direction, amount, target weights)
     * @return inMin Minimum amounts for each position (slippage protection)
     * @return preview Detailed preview of the rebalance operation
     */
    function getAmountsForInitialDepositWithSwapAndPreview(
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
        // Fetch sqrtPriceX96 from initialized pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        return getAmountsForInitialDepositWithSwapAndPreview(poolKey, sqrtPriceX96, params);
    }

    /**
     * @notice Calculate swap needed for initial deposit with any token ratio, then preview positions
     * @dev FOR UNINITIALIZED POOLS ONLY - Supports any ratio: 100/0, 90/10, 50/50, etc. Calculates optimal swap to achieve strategy weights
     * @param poolKey The PoolKey for the Uniswap V4 pool
     * @param sqrtPriceX96 The intended sqrtPriceX96 for pool initialization
     * @param params Parameters including both token amounts (any ratio)
     * @return finalAmount0 Amount of token0 after optimal swap
     * @return finalAmount1 Amount of token1 after optimal swap
     * @return swapParams Swap details (direction, amount, target weights)
     * @return inMin Minimum amounts for each position (slippage protection)
     * @return preview Detailed preview of the rebalance operation
     */
    function getAmountsForInitialDepositWithSwapAndPreview(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        SimpleLensInMin.InitialDepositWithSwapParams calldata params
    )
        public
        view
        returns (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            SimpleLensInMin.RebalancePreview memory preview
        )
    {
        return InitialDepositLensLogic.getAmountsForInitialDepositWithSwapAndPreview(poolKey, sqrtPriceX96, params);
    }

    /**
     * @notice Struct to store position statistics
     */
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

    /**
     * @notice Get detailed statistics for all positions in a MultiPositionManager
     * @param manager The MultiPositionManager contract to query
     * @return stats Array of statistics for each position
     */
    function getPositionStats(IMultiPositionManager manager) public view returns (PositionStats[] memory stats) {
        PoolKey memory poolKey = manager.poolKey();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        stats = new PositionStats[](ranges.length);
        uint256 baseLen = manager.basePositionsLength();

        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) {
                continue;
            }

            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(ranges[i].lowerTick);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(ranges[i].upperTick);

            (uint256 token0Quantity, uint256 token1Quantity) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(positionData[i].liquidity)
            );

            uint256 token0ValueInToken1 =
                FullMath.mulDiv(token0Quantity, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
            uint256 valueInToken1 = token0ValueInToken1 + token1Quantity;

            stats[i] = PositionStats({
                tickLower: ranges[i].lowerTick,
                tickUpper: ranges[i].upperTick,
                sqrtPriceLower: sqrtPriceLowerX96,
                sqrtPriceUpper: sqrtPriceUpperX96,
                liquidity: uint128(positionData[i].liquidity),
                token0Quantity: token0Quantity,
                token1Quantity: token1Quantity,
                valueInToken1: valueInToken1,
                isLimit: i >= baseLen
            });
        }
    }
}
