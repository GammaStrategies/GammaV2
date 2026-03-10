// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {wadExp} from "solmate/src/utils/SignedWadMath.sol";

/**
 * @title LiquidityDistributionLibrary
 * @notice Library for mathematical functions used in liquidity distribution strategies
 * @dev Implements approximations for exp, gaussian, and other mathematical functions
 */
library LiquidityDistributionLibrary {
    uint256 constant WAD = 1e18;
    uint256 constant HALF_WAD = 5e17;

    /**
     * @notice Calculate the absolute difference between two int24 values
     * @param a First value
     * @param b Second value
     * @return The absolute difference as uint256
     */
    function absDiff(int24 a, int24 b) internal pure returns (uint256) {
        return a > b ? uint256(int256(a - b)) : uint256(int256(b - a));
    }

    /**
     * @notice Calculate the center tick of a position
     * @param lowerTick Lower tick of the position
     * @param upperTick Upper tick of the position
     * @return Center tick of the position
     */
    function centerTick(int24 lowerTick, int24 upperTick) internal pure returns (int24) {
        return (lowerTick + upperTick) / 2;
    }

    /**
     * @notice Approximate exponential function using Taylor series
     * @dev exp(x) ≈ 1 + x + x²/2 + x³/6 + x⁴/24 for small x
     * @param x Input scaled by WAD (negative values for decay)
     * @return Approximation of exp(x) scaled by WAD
     */
    function exp(int256 x) internal pure returns (uint256) {
        // Use solmate's wadExp for precise exponential calculation
        int256 result = wadExp(x);
        // Convert to uint256, ensuring non-negative
        return result > 0 ? uint256(result) : 0;
    }

    /**
     * @notice Calculate gaussian-like density
     * @dev Uses exp(-(x²/2σ²)) approximation
     * @param distance Distance from center (absolute value)
     * @param sigma Standard deviation scaled by WAD
     * @return Gaussian density value scaled by WAD
     */
    function gaussian(uint256 distance, uint256 sigma) internal pure returns (uint256) {
        if (sigma == 0) return distance == 0 ? WAD : 0;

        // Calculate -(distance²)/(2σ²)
        // Scale down to prevent overflow
        uint256 scaledDist = (distance * WAD) / sigma;

        // If distance is too large, return minimal value
        if (scaledDist > 3 * WAD) return 1; // Beyond 3 sigma

        // Calculate exp(-(scaledDist²)/2)
        uint256 exponent = (scaledDist * scaledDist) / (2 * WAD);
        return exp(-int256(exponent));
    }

    /**
     * @notice Calculate triangle distribution density
     * @param distance Distance from center
     * @param maxDistance Maximum distance (triangle base)
     * @return Triangle density value scaled by WAD
     */
    function triangle(uint256 distance, uint256 maxDistance) internal pure returns (uint256) {
        if (maxDistance == 0 || distance >= maxDistance) return 0;

        // Linear decay from center: (1 - distance/maxDistance)
        return WAD - (distance * WAD) / maxDistance;
    }

    /**
     * @notice Calculate exponential distribution density
     * @param distance Distance from center
     * @param lambda Decay parameter scaled by WAD
     * @return Exponential density value scaled by WAD
     */
    function exponential(uint256 distance, uint256 lambda) internal pure returns (uint256) {
        if (lambda == 0) return distance == 0 ? WAD : 0;

        // Calculate exp(-distance/lambda)
        int256 exponent = -int256((distance * WAD) / lambda);
        return exp(exponent);
    }

    /**
     * @notice Normalize an array of weights to sum to WAD
     * @param weights Array of weights to normalize
     * @return normalized Array of normalized weights
     */
    function normalize(uint256[] memory weights) internal pure returns (uint256[] memory normalized) {
        uint256 length = weights.length;
        normalized = new uint256[](length);

        // Calculate sum
        uint256 sum;
        for (uint256 i = 0; i < length;) {
            unchecked {
                sum += weights[i];
                ++i;
            }
        }

        // If sum is zero, distribute equally
        if (sum == 0) {
            uint256 equalWeight = WAD / length;
            uint256 remainder;
            unchecked {
                remainder = WAD - (equalWeight * length);
            }
            for (uint256 i = 0; i < length;) {
                normalized[i] = equalWeight;
                if (i == length - 1) {
                    unchecked {
                        normalized[i] += remainder;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            return normalized;
        }

        // Normalize to sum = WAD
        uint256 normalizedSum;
        for (uint256 i = 0; i < length;) {
            if (i == length - 1) {
                // Last element gets the remainder to ensure exact sum
                normalized[i] = WAD - normalizedSum;
            } else {
                normalized[i] = (weights[i] * WAD) / sum;
                unchecked {
                    normalizedSum += normalized[i];
                }
            }
            unchecked {
                ++i;
            }
        }

        return normalized;
    }

    /**
     * @notice Calculate camel distribution (double-peaked)
     * @param distance Distance from center
     * @param maxDistance Maximum distance
     * @param peakOffset Offset of peaks from center (as fraction of maxDistance)
     * @return Camel density value scaled by WAD
     */
    function camel(uint256 distance, uint256 maxDistance, uint256 peakOffset) internal pure returns (uint256) {
        if (maxDistance == 0) return 0;

        // Create two peaks at ±peakOffset from center
        uint256 leftPeak = (maxDistance * peakOffset) / WAD;
        uint256 rightPeak = leftPeak;

        // Calculate distance to nearest peak
        uint256 distToLeft = distance > leftPeak ? distance - leftPeak : leftPeak - distance;
        uint256 distToRight = distance > rightPeak ? distance - rightPeak : rightPeak - distance;
        uint256 minDist = distToLeft < distToRight ? distToLeft : distToRight;

        // Use gaussian-like decay from nearest peak
        uint256 sigma = maxDistance / 3;
        uint256 density = gaussian(minDist, sigma);

        // Add base level to connect the peaks
        return density + (WAD / 10); // Add 10% base level
    }
}
