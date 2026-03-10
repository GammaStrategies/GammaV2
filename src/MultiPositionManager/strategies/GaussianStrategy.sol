// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./ILiquidityStrategy.sol";
import "./LiquidityDistributionLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {wadExp} from "solmate/src/utils/SignedWadMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title GaussianStrategy
 * @notice Gaussian distribution with center-aligned odd-number range generation
 * @dev Key features:
 *      1. Dynamic range count, forced odd - guarantees single center range
 *      2. Center-aligned grid: ranges are generated relative to centerTick, not 0
 *      3. Clamped ticksLeft/ticksRight for proper sigma calculation
 */
contract GaussianStrategy is ILiquidityStrategy {
    struct DensityParams {
        int24[] lowerTicks;
        int24[] upperTicks;
        int24 currentTick;
        int24 centerTick;
        uint24 ticksLeft;
        uint24 ticksRight;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet;
        int24 tickSpacing;
        bool useAssetWeights;
    }

    /**
     * @notice Generate ranges with optional full-range floor position
     * @dev Uses center-aligned grid with odd number of ranges
     */
    function generateRanges(int24 centerTick, uint24 ticksLeft, uint24 ticksRight, int24 tickSpacing, bool useCarpet)
        external
        pure
        override
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        return _generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);
    }

    struct GridParams {
        int24 centerTick;
        int24 width;
        int24 leftBound;
        int24 rightBound;
        int24 minUsable;
        int24 maxUsable;
        uint256 numRanges;
    }

    function _generateRanges(int24 centerTick, uint24 ticksLeft, uint24 ticksRight, int24 tickSpacing, bool useCarpet)
        internal
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        // Align center tick to tick spacing
        centerTick = (centerTick / tickSpacing) * tickSpacing;

        GridParams memory grid = _calculateGridParams(centerTick, ticksLeft, ticksRight, tickSpacing);

        (int24[] memory baseLowers, int24[] memory baseUppers) =
            _generateStandardRanges(grid.leftBound, grid.rightBound, grid.width, centerTick);

        if (!useCarpet) {
            return (baseLowers, baseUppers);
        }

        return _prependFullRangeFloor(baseLowers, baseUppers, tickSpacing);
    }

    function _calculateGridParams(int24 centerTick, uint24 ticksLeft, uint24 ticksRight, int24 tickSpacing)
        private
        pure
        returns (GridParams memory grid)
    {
        grid.centerTick = centerTick;
        grid.minUsable = TickMath.minUsableTick(tickSpacing);
        grid.maxUsable = TickMath.maxUsableTick(tickSpacing);

        // Calculate raw bounds
        (int24 rawLeftBound, int24 rawRightBound) = _calculateRawBounds(centerTick, ticksLeft, ticksRight, grid.minUsable, grid.maxUsable);

        // Calculate width and numRanges dynamically
        (grid.width, grid.numRanges) = _calculateWidthAndNumRanges(rawLeftBound, rawRightBound, tickSpacing);

        // Calculate center-aligned bounds
        (grid.leftBound, grid.rightBound) = _calculateCenterAlignedBounds(
            centerTick, grid.width, grid.numRanges, tickSpacing, grid.minUsable, grid.maxUsable
        );
    }

    function _calculateRawBounds(int24 centerTick, uint24 ticksLeft, uint24 ticksRight, int24 minUsable, int24 maxUsable)
        private
        pure
        returns (int24 rawLeftBound, int24 rawRightBound)
    {
        int256 tempLeft = int256(centerTick) - int256(uint256(ticksLeft));
        rawLeftBound = tempLeft < int256(minUsable) ? minUsable : int24(tempLeft);

        int256 tempRight = int256(centerTick) + int256(uint256(ticksRight));
        rawRightBound = tempRight > int256(maxUsable) ? maxUsable : int24(tempRight);
    }

    function _calculateWidthAndNumRanges(int24 rawLeftBound, int24 rawRightBound, int24 tickSpacing)
        private
        pure
        returns (int24 width, uint256 numRanges)
    {
        uint256 actualSpan = uint256(int256(rawRightBound) - int256(rawLeftBound));

        // Calculate width (target ~20 ranges)
        uint256 targetRanges = 20;
        uint256 divisor = targetRanges * uint24(tickSpacing);
        width = int24(uint24(((actualSpan + divisor - 1) / divisor) * uint24(tickSpacing)));
        if (width < tickSpacing) width = tickSpacing;

        // Calculate actual number of ranges
        numRanges = actualSpan / uint256(int256(width));
        if (numRanges == 0) numRanges = 1;

        // If even, add 1 to make odd (guarantees single center range)
        if (numRanges % 2 == 0) {
            numRanges += 1;
        }
    }

    function _calculateCenterAlignedBounds(
        int24 centerTick,
        int24 width,
        uint256 numRanges,
        int24 tickSpacing,
        int24 minUsable,
        int24 maxUsable
    ) private pure returns (int24 leftBound, int24 rightBound) {
        // Clamp centerTick to usable bounds first to prevent overflow
        if (centerTick < minUsable) centerTick = minUsable;
        if (centerTick > maxUsable) centerTick = maxUsable;

        // Use int256 for intermediate calculations to prevent overflow
        int256 halfWidthInt = int256(width) / 2;
        int256 centerRangeLowerInt = int256(centerTick) - halfWidthInt;
        centerRangeLowerInt = (centerRangeLowerInt / int256(tickSpacing)) * int256(tickSpacing);
        int256 centerRangeUpperInt = centerRangeLowerInt + int256(width);

        // Calculate how many ranges on each side
        uint256 halfRanges = numRanges / 2;
        int256 widthInt = int256(uint256(int256(width)));

        // Left bound: start from centerRangeLower and go left by halfRanges
        int256 leftBoundInt = centerRangeLowerInt - int256(halfRanges) * widthInt;
        if (leftBoundInt < int256(minUsable)) leftBoundInt = int256(minUsable);
        leftBound = int24(leftBoundInt);

        // Right bound: start from centerRangeUpper and go right by halfRanges
        int256 rightBoundInt = centerRangeUpperInt + int256(halfRanges) * widthInt;
        if (rightBoundInt > int256(maxUsable)) rightBoundInt = int256(maxUsable);
        rightBound = int24(rightBoundInt);
    }

    function _generateStandardRanges(int24 leftBound, int24 rightBound, int24 width, int24 /* centerTick */)
        private
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        // Count how many ranges we'll create
        uint256 numRanges;
        int256 currentInt = int256(leftBound);
        int256 rightBoundInt = int256(rightBound);
        int256 widthInt = int256(uint256(int256(width)));
        while (currentInt < rightBoundInt) {
            unchecked {
                ++numRanges;
            }
            currentInt += widthInt;
        }

        // Allocate arrays
        lowerTicks = new int24[](numRanges);
        upperTicks = new int24[](numRanges);

        // Generate non-overlapping ranges
        int24 current = leftBound;
        for (uint256 i = 0; i < numRanges;) {
            lowerTicks[i] = current;

            int256 nextUpper = int256(current) + int256(uint256(int256(width)));
            if (nextUpper > int256(type(int24).max)) {
                upperTicks[i] = type(int24).max;
            } else {
                upperTicks[i] = int24(nextUpper);
            }

            if (upperTicks[i] > rightBound) {
                upperTicks[i] = rightBound;
            }

            int256 nextCurrent = int256(current) + int256(uint256(int256(width)));
            if (nextCurrent <= int256(type(int24).max)) {
                current = int24(nextCurrent);
            } else {
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _prependFullRangeFloor(int24[] memory baseLowers, int24[] memory baseUppers, int24 tickSpacing)
        private
        pure
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        uint256 length = baseLowers.length;

        if (length == 0) {
            lowerTicks = new int24[](1);
            upperTicks = new int24[](1);
            lowerTicks[0] = minUsable;
            upperTicks[0] = maxUsable;
            return (lowerTicks, upperTicks);
        }

        uint256 floorIdx = type(uint256).max;
        for (uint256 i = 0; i < length; ++i) {
            if (_isFullRange(baseLowers[i], baseUppers[i], minUsable, maxUsable)) {
                floorIdx = i;
                break;
            }
        }

        if (floorIdx == 0) {
            return (baseLowers, baseUppers);
        }

        if (floorIdx == type(uint256).max) {
            lowerTicks = new int24[](length + 1);
            upperTicks = new int24[](length + 1);
            lowerTicks[0] = minUsable;
            upperTicks[0] = maxUsable;
            for (uint256 i = 0; i < length; ++i) {
                lowerTicks[i + 1] = baseLowers[i];
                upperTicks[i + 1] = baseUppers[i];
            }
            return (lowerTicks, upperTicks);
        }

        lowerTicks = new int24[](length);
        upperTicks = new int24[](length);
        lowerTicks[0] = minUsable;
        upperTicks[0] = maxUsable;

        uint256 idx = 1;
        for (uint256 i = 0; i < length; ++i) {
            if (i == floorIdx) {
                continue;
            }
            lowerTicks[idx] = baseLowers[i];
            upperTicks[idx] = baseUppers[i];
            unchecked {
                ++idx;
            }
        }
    }

    function _isFullRange(int24 lowerTick, int24 upperTick, int24 minUsable, int24 maxUsable)
        private
        pure
        returns (bool)
    {
        return lowerTick == minUsable && upperTick == maxUsable;
    }

    /**
     * @notice Calculate Gaussian density with all options
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
    ) public pure override returns (uint256[] memory weights) {
        DensityParams memory params = DensityParams({
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            currentTick: currentTick,
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            weight0: weight0,
            weight1: weight1,
            useCarpet: useCarpet,
            tickSpacing: tickSpacing,
            useAssetWeights: useAssetWeights
        });

        return _calculateDensitiesInternal(params);
    }

    function _calculateDensitiesInternal(DensityParams memory params) private pure returns (uint256[] memory weights) {
        uint256 numRanges = params.lowerTicks.length;
        weights = new uint256[](numRanges);

        if (numRanges == 0) return weights;

        if (params.useCarpet && numRanges > 1) {
            int24 minUsable = TickMath.minUsableTick(params.tickSpacing);
            int24 maxUsable = TickMath.maxUsableTick(params.tickSpacing);
            if (params.lowerTicks[0] == minUsable && params.upperTicks[0] == maxUsable) {
                int24[] memory baseLower = new int24[](numRanges - 1);
                int24[] memory baseUpper = new int24[](numRanges - 1);
                for (uint256 i = 1; i < numRanges; ++i) {
                    baseLower[i - 1] = params.lowerTicks[i];
                    baseUpper[i - 1] = params.upperTicks[i];
                }

                DensityParams memory baseParams = params;
                baseParams.lowerTicks = baseLower;
                baseParams.upperTicks = baseUpper;

                uint256[] memory baseWeights = new uint256[](numRanges - 1);
                _processWeightsNoCarpet(baseWeights, baseParams);
                weights[0] = 0;
                for (uint256 i = 0; i < baseWeights.length; ++i) {
                    weights[i + 1] = baseWeights[i];
                }
                return weights;
            }
        }

        // Validate weights sum to 1e18 (skip for proportional weights)
        if (!params.useAssetWeights) {
            require(params.weight0 + params.weight1 == 1e18, "Weights must sum to 1e18");
        }

        _processWeightsNoCarpet(weights, params);
        _applyFullRangeFloorWeight(weights, params);

        return weights;
    }

    function _processWeightsNoCarpet(uint256[] memory weights, DensityParams memory params) private pure {
        uint256 numRanges = params.lowerTicks.length;

        // Find the center range (contains centerTick) to get BOTH bounds for symmetric distance calculation
        int24 centerRangeLower = params.centerTick; // fallback
        int24 centerRangeUpper = params.centerTick; // fallback
        for (uint256 i = 0; i < numRanges;) {
            if (params.lowerTicks[i] <= params.centerTick && params.centerTick < params.upperTicks[i]) {
                centerRangeLower = params.lowerTicks[i];
                centerRangeUpper = params.upperTicks[i];
                break;
            }
            unchecked { ++i; }
        }
        // Use the midpoint of the center range for symmetric distance calculation
        int24 centerMidpoint = (centerRangeLower + centerRangeUpper) / 2;

        // Calculate CLAMPED sigma based on actual range bounds (not requested ticksLeft/ticksRight)
        // This ensures proper decay when ticksLeft/ticksRight exceed minUsableTick/maxUsableTick
        uint256 sigmaLeft;
        uint256 sigmaRight;
        {
            // Symmetric: left uses centerRangeLower, right uses centerRangeUpper
            int256 leftSpan = int256(centerRangeLower) - int256(params.lowerTicks[0]);
            uint256 actualLeftSpan = leftSpan > 0 ? uint256(leftSpan) : 0;
            uint256 effectiveTicksLeft =
                actualLeftSpan < uint256(params.ticksLeft) ? actualLeftSpan : uint256(params.ticksLeft);

            int256 rightSpan = int256(params.upperTicks[numRanges - 1]) - int256(centerRangeUpper);
            uint256 actualRightSpan = rightSpan > 0 ? uint256(rightSpan) : 0;
            uint256 effectiveTicksRight =
                actualRightSpan < uint256(params.ticksRight) ? actualRightSpan : uint256(params.ticksRight);

            sigmaLeft = effectiveTicksLeft / 3;
            sigmaRight = effectiveTicksRight / 3;
        }
        if (sigmaLeft == 0) sigmaLeft = 1;
        if (sigmaRight == 0) sigmaRight = 1;

        // Calculate base Gaussian weights
        uint256[] memory baseWeights = new uint256[](numRanges);
        uint256 totalBaseWeight;

        for (uint256 i = 0; i < numRanges;) {
            bool isLeftOfCenter;
            uint256 absDistance;

            // Calculate distance from centerMidpoint to range's midpoint (not edge)
            // This ensures symmetric weights for both small and large ticksLeft/ticksRight
            int24 rangeMidpoint = (params.lowerTicks[i] + params.upperTicks[i]) / 2;
            int256 dist = int256(rangeMidpoint) - int256(centerMidpoint);
            absDistance = dist < 0 ? uint256(-dist) : uint256(dist);

            // Determine if left or right of center for sigma selection
            isLeftOfCenter = rangeMidpoint < centerMidpoint;

            // Use appropriate sigma based on side
            uint256 sigma = isLeftOfCenter ? sigmaLeft : sigmaRight;

            // Apply true Gaussian formula: exp(-0.5 * (distance/sigma)²)
            uint256 weight;
            if (absDistance < sigma * 6) {
                // 6-sigma covers 99.9997% of distribution
                // Normalize distance by sigma
                int256 normalizedDist = int256((absDistance * 1e18) / sigma);
                // Calculate -0.5 * (normalized_distance)²
                int256 exponent = -(normalizedDist * normalizedDist) / 2e18;
                // Apply exponential
                int256 expResult = wadExp(exponent);
                weight = expResult != 0 ? uint256(expResult) : 0;
            } else {
                weight = 0; // Beyond 6-sigma, negligible
            }

            baseWeights[i] = weight;
            unchecked {
                totalBaseWeight += baseWeights[i];
                ++i;
            }
        }

        // Apply weight preferences
        if (params.useAssetWeights) {
            // Proportional weights: use base distribution (no filtering)
            if (totalBaseWeight != 0) {
                for (uint256 i = 0; i < numRanges;) {
                    weights[i] = FullMath.mulDiv(baseWeights[i], LiquidityDistributionLibrary.WAD, totalBaseWeight);
                    unchecked {
                        ++i;
                    }
                }
            }
        } else {
            // Explicit preferences: apply weight-based filtering
            uint256[] memory adjustedWeights = new uint256[](numRanges);
            uint256 totalAdjustedWeight;

            for (uint256 i = 0; i < numRanges;) {
                if (params.upperTicks[i] <= params.currentTick) {
                    adjustedWeights[i] = FullMath.mulDiv(baseWeights[i] * params.weight1, 2, 1e18);
                } else if (params.lowerTicks[i] >= params.currentTick) {
                    adjustedWeights[i] = FullMath.mulDiv(baseWeights[i] * params.weight0, 2, 1e18);
                } else {
                    adjustedWeights[i] = baseWeights[i];
                }
                unchecked {
                    totalAdjustedWeight += adjustedWeights[i];
                    ++i;
                }
            }

            // Normalize to sum to 1e18
            if (totalAdjustedWeight != 0) {
                for (uint256 i = 0; i < numRanges;) {
                    weights[i] =
                        FullMath.mulDiv(adjustedWeights[i], LiquidityDistributionLibrary.WAD, totalAdjustedWeight);
                    unchecked {
                        ++i;
                    }
                }
            }
        }
    }

    function _applyFullRangeFloorWeight(uint256[] memory weights, DensityParams memory params) private pure {
        if (!params.useCarpet || weights.length == 0) {
            return;
        }

        int24 minUsable = TickMath.minUsableTick(params.tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(params.tickSpacing);

        if (params.lowerTicks[0] != minUsable || params.upperTicks[0] != maxUsable) {
            return;
        }

        if (weights.length == 1) {
            weights[0] = LiquidityDistributionLibrary.WAD;
            return;
        }

        uint256 sum;
        for (uint256 i = 1; i < weights.length; ++i) {
            sum += weights[i];
        }

        if (sum == 0) {
            weights[0] = 0;
            return;
        }

        for (uint256 i = 1; i < weights.length; ++i) {
            weights[i] = FullMath.mulDiv(weights[i], LiquidityDistributionLibrary.WAD, sum);
        }
        weights[0] = 0;
    }

    /**
     * @notice This strategy supports weighted distribution
     */
    function supportsWeights() external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Get strategy type identifier
     */
    function getStrategyType() external pure override returns (string memory) {
        return "Gaussian";
    }

    /**
     * @notice Get human-readable description
     */
    function getDescription() external pure override returns (string memory) {
        return "Gaussian distribution with optional full-range floor and weight preferences";
    }
}
