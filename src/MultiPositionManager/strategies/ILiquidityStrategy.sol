// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title ILiquidityStrategy
 * @notice Interface for liquidity distribution strategies matching Python shapes
 * @dev Each strategy implements a different distribution pattern (uniform, triangle, gaussian, etc.)
 */
interface ILiquidityStrategy {
    /**
     * @notice Generate tick ranges with optional full-range floor position
     * @param centerTick The center tick for the strategy
     * @param ticksLeft Number of ticks to the left of center for the distribution
     * @param ticksRight Number of ticks to the right of center for the distribution
     * @param tickSpacing The tick spacing of the pool
     * @param useCarpet Whether to add a full-range floor position (min/max usable ticks)
     * @return lowerTicks Array of lower ticks for each position
     * @return upperTicks Array of upper ticks for each position
     */
    function generateRanges(int24 centerTick, uint24 ticksLeft, uint24 ticksRight, int24 tickSpacing, bool useCarpet)
        external
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks);

    /**
     * @notice Get the strategy type identifier
     * @return strategyType String identifier for the strategy (e.g., "uniform", "triangle", "gaussian")
     */
    function getStrategyType() external pure returns (string memory strategyType);

    /**
     * @notice Get a description of the strategy
     * @return description Human-readable description of the distribution pattern
     */
    function getDescription() external pure returns (string memory description);

    /**
     * @notice Check if this strategy supports weighted distribution
     * @return supported True if the strategy implements calculateDensitiesWithWeights
     */
    function supportsWeights() external pure returns (bool supported);

    /**
     * @notice Calculate density weights with token weights and optional full-range floor
     * @dev Comprehensive function that supports both token weights and full-range floor ranges
     * @param lowerTicks Array of lower ticks for each position
     * @param upperTicks Array of upper ticks for each position
     * @param currentTick Current tick of the pool
     * @param centerTick Center tick for the distribution
     * @param ticksLeft Number of ticks to the left of center for the shape
     * @param ticksRight Number of ticks to the right of center for the shape
     * @param weight0 Weight preference for token0 (scaled to 1e18, e.g., 0.8e18 for 80%)
     * @param weight1 Weight preference for token1 (scaled to 1e18, e.g., 0.2e18 for 20%)
     * @param useCarpet Whether a full-range floor position is present
     * @param tickSpacing The tick spacing of the pool
     * @param useAssetWeights True if weights were auto-calculated from available tokens (should not filter ranges)
     * @return weights Array of weights for each position (scaled to 1e18, sum = 1e18)
     */
    function calculateDensities(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        int24 currentTick,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        uint256 weight0,
        uint256 weight1,
        bool useCarpet,
        int24 tickSpacing,
        bool useAssetWeights
    ) external pure returns (uint256[] memory weights);
}
