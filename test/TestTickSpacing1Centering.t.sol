// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title TestTickSpacing1Centering
 * @notice Tests the centering issue for tickSpacing=1 pools in ExponentialStrategy
 */
contract TestTickSpacing1Centering is Test {
    ExponentialStrategy strategy;

    function setUp() public {
        strategy = new ExponentialStrategy();
    }

    /**
     * @notice Demonstrate the centering bug for tickSpacing=1
     * With centerTick=100, ticksLeft=10, ticksRight=10, tickSpacing=1:
     * Expected: Ranges should be symmetric around tick 100
     * Actual: Ranges might be offset to the left
     */
    function test_CenteringBugTickSpacing1() public {
        int24 centerTick = 100;
        uint24 ticksLeft = 10;
        uint24 ticksRight = 10;
        int24 tickSpacing = 1;

        console2.log("\n=== Centering Bug Test for tickSpacing=1 ===");
        console2.log("Center tick:", centerTick);
        console2.log("Ticks left:", ticksLeft);
        console2.log("Ticks right:", ticksRight);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, false);

        console2.log("\nGenerated ranges:");
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            int256 midpoint = (int256(lowerTicks[i]) + int256(upperTicks[i])) / 2;
            console2.log("Range", i);
            console2.log("  Lower:", lowerTicks[i]);
            console2.log("  Upper:", upperTicks[i]);
            console2.log("  Midpoint:", midpoint);
        }

        // Check that some range contains the center tick
        bool foundCenter = false;
        uint256 centerRangeIdx;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] <= centerTick && centerTick < upperTicks[i]) {
                foundCenter = true;
                centerRangeIdx = i;
                console2.log("\nRange containing center is index:", i);
                break;
            }
        }
        assertTrue(foundCenter, "Should have a range containing center tick");

        // Now calculate densities
        uint256[] memory weights = _calculateDensities(lowerTicks, upperTicks, centerTick, ticksLeft, ticksRight, tickSpacing);

        // Find max weight
        uint256 maxWeight = 0;
        uint256 maxWeightIndex = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            console2.log("Range", i, "weight:", weights[i]);
            if (weights[i] > maxWeight) {
                maxWeight = weights[i];
                maxWeightIndex = i;
            }
        }

        console2.log("\nMax weight at index:", maxWeightIndex);

        // Visualize weight distribution
        _visualizeWeights(lowerTicks, upperTicks, weights, centerTick);

        // The max weight should be at or adjacent to the center-containing range
        bool maxContainsCenter = lowerTicks[maxWeightIndex] <= centerTick && centerTick < upperTicks[maxWeightIndex];
        console2.log("Max weight range contains center:", maxContainsCenter);

        assertTrue(maxContainsCenter, "Max weight range should contain center tick");
    }

    /**
     * @notice Test with odd center tick
     */
    function test_CenteringOddTick() public {
        int24 centerTick = 5;
        uint24 ticksLeft = 10;
        uint24 ticksRight = 10;
        int24 tickSpacing = 1;

        console2.log("\n=== Centering Test for odd center tick ===");
        console2.log("Center tick:", centerTick);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, false);

        console2.log("Generated", lowerTicks.length, "ranges");

        // Find center-containing range
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] <= centerTick && centerTick < upperTicks[i]) {
                int256 midpoint = (int256(lowerTicks[i]) + int256(upperTicks[i])) / 2;
                console2.log("Center range lower:", lowerTicks[i]);
                console2.log("Center range upper:", upperTicks[i]);
                console2.log("Midpoint:", midpoint);
                console2.log("Midpoint offset from center:", midpoint - int256(centerTick));
                break;
            }
        }

        uint256[] memory weights = _calculateDensities(lowerTicks, upperTicks, centerTick, ticksLeft, ticksRight, tickSpacing);

        // Find max weight
        uint256 maxWeightIndex = 0;
        uint256 maxWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i] > maxWeight) {
                maxWeight = weights[i];
                maxWeightIndex = i;
            }
        }

        // Visualize weight distribution
        _visualizeWeights(lowerTicks, upperTicks, weights, centerTick);

        bool maxContainsCenter = lowerTicks[maxWeightIndex] <= centerTick && centerTick < upperTicks[maxWeightIndex];
        console2.log("\nMax weight index:", maxWeightIndex);
        console2.log("Max weight range lower:", lowerTicks[maxWeightIndex]);
        console2.log("Max weight range upper:", upperTicks[maxWeightIndex]);
        console2.log("Max weight range contains center:", maxContainsCenter);

        assertTrue(maxContainsCenter, "Max weight range should contain center tick");
    }

    /**
     * @notice Test asymmetry in range distribution
     * The bug might be that the LEFT side has more ticks than the RIGHT side
     * because the range [centerTick, centerTick+width) is counted as right but starts AT center
     */
    function test_RangeDistributionSymmetry() public view {
        int24 centerTick = 100;
        uint24 ticksLeft = 10;
        uint24 ticksRight = 10;
        int24 tickSpacing = 1;

        console2.log("\n=== Range Distribution Symmetry Test ===");

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, false);

        // Count how many ranges are fully left of center, at center, and fully right of center
        uint256 leftCount = 0;
        uint256 centerCount = 0;
        uint256 rightCount = 0;

        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (upperTicks[i] <= centerTick) {
                leftCount++;
            } else if (lowerTicks[i] >= centerTick) {
                // This range starts at or after center - but does it contain center?
                if (lowerTicks[i] == centerTick) {
                    centerCount++;
                } else {
                    rightCount++;
                }
            } else {
                // This range straddles center (lowerTick < centerTick < upperTick)
                centerCount++;
            }
        }

        console2.log("Ranges fully LEFT of center (upperTick <= center):", leftCount);
        console2.log("Ranges containing CENTER:", centerCount);
        console2.log("Ranges fully RIGHT of center (lowerTick > center):", rightCount);

        // The first tick (leftBound) and last tick (rightBound)
        console2.log("\nFirst range lower:", lowerTicks[0]);
        console2.log("First range upper:", upperTicks[0]);
        console2.log("Last range lower:", lowerTicks[lowerTicks.length-1]);
        console2.log("Last range upper:", upperTicks[upperTicks.length-1]);

        // Distance from center
        int256 leftDistance = int256(centerTick) - int256(lowerTicks[0]);
        int256 rightDistance = int256(upperTicks[upperTicks.length-1]) - int256(centerTick);

        console2.log("\nDistance from center to leftmost bound:", leftDistance);
        console2.log("Distance from center to rightmost bound:", rightDistance);

        // For symmetric distribution, these should be equal (or differ by 1 at most)
        int256 asymmetry = leftDistance - rightDistance;
        console2.log("Asymmetry (left - right):", asymmetry);
    }

    /**
     * @notice Test with a "real world" pool tick value
     * Let's simulate what might happen with a real pool
     */
    function test_RealWorldPoolTick() public view {
        // A typical stablecoin pool might have a tick around 0
        // But let's test with an arbitrary value
        int24 centerTick = -23456;  // Some arbitrary tick
        uint24 ticksLeft = 100;
        uint24 ticksRight = 100;
        int24 tickSpacing = 1;

        console2.log("\n=== Real World Pool Tick Test ===");
        console2.log("Center tick:", centerTick);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, false);

        // Check if center tick is properly contained
        bool foundCenter = false;
        uint256 centerIdx = 0;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] <= centerTick && centerTick < upperTicks[i]) {
                foundCenter = true;
                centerIdx = i;
                int256 midpoint = (int256(lowerTicks[i]) + int256(upperTicks[i])) / 2;
                console2.log("Center range index:", i);
                console2.log("Center range lower:", lowerTicks[i]);
                console2.log("Center range upper:", upperTicks[i]);
                console2.log("Midpoint:", midpoint);
                console2.log("Midpoint offset from center:", midpoint - int256(centerTick));
                break;
            }
        }

        assertTrue(foundCenter, "Should find a range containing center");

        // Calculate weights
        uint256[] memory weights = _calculateDensities(lowerTicks, upperTicks, centerTick, ticksLeft, ticksRight, tickSpacing);

        // Find max weight
        uint256 maxWeightIndex = 0;
        uint256 maxWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i] > maxWeight) {
                maxWeight = weights[i];
                maxWeightIndex = i;
            }
        }

        console2.log("\nMax weight index:", maxWeightIndex);
        console2.log("Max weight range lower:", lowerTicks[maxWeightIndex]);
        console2.log("Max weight range upper:", upperTicks[maxWeightIndex]);

        bool maxContainsCenter = lowerTicks[maxWeightIndex] <= centerTick && centerTick < upperTicks[maxWeightIndex];
        console2.log("Max weight range contains center:", maxContainsCenter);

        assertTrue(maxContainsCenter, "Max weight range should contain center tick");
    }

    /**
     * @notice Test tickSpacing=60 case to ensure no regression
     */
    function test_TickSpacing60() public view {
        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        console2.log("\n=== Test tickSpacing=60 ===");
        console2.log("Center tick:", centerTick);
        console2.log("Ticks left:", ticksLeft);
        console2.log("Ticks right:", ticksRight);

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            strategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, false);

        console2.log("Number of ranges:", lowerTicks.length);
        console2.log("First range lower:", lowerTicks[0]);
        console2.log("First range upper:", upperTicks[0]);
        console2.log("Last range lower:", lowerTicks[lowerTicks.length-1]);
        console2.log("Last range upper:", upperTicks[upperTicks.length-1]);

        // Find center-containing range
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] <= centerTick && centerTick < upperTicks[i]) {
                int256 midpoint = (int256(lowerTicks[i]) + int256(upperTicks[i])) / 2;
                console2.log("Center range index:", i);
                console2.log("Center range lower:", lowerTicks[i]);
                console2.log("Center range upper:", upperTicks[i]);
                console2.log("Midpoint:", midpoint);
                break;
            }
        }
    }

    struct TokenVizParams {
        int24[] lowerTicks;
        int24[] upperTicks;
        uint256[] weights;
        int24 centerTick;
        uint256 centerIdx;
        uint256 maxWeight;
    }

    /**
     * @notice ASCII visualization of weight distribution with token amounts
     */
    function _visualizeWeights(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        uint256[] memory weights,
        int24 centerTick
    ) internal pure {
        // Find max weight and center index
        uint256 maxWeight = 0;
        uint256 centerIdx = type(uint256).max;
        for (uint256 i = 0; i < weights.length; i++) {
            if (weights[i] > maxWeight) {
                maxWeight = weights[i];
            }
            if (lowerTicks[i] <= centerTick && centerTick < upperTicks[i]) {
                centerIdx = i;
            }
        }

        TokenVizParams memory p = TokenVizParams({
            lowerTicks: lowerTicks,
            upperTicks: upperTicks,
            weights: weights,
            centerTick: centerTick,
            centerIdx: centerIdx,
            maxWeight: maxWeight
        });

        console2.log("\n=== TOKEN VALUE DISTRIBUTION ===");
        console2.log("Legend: # = Token0 value, = = Token1 value, * = contains centerTick");
        console2.log("Simulated deposit: 100 units total value");
        console2.log("--------------------------------------------------------------------------------");

        uint256 totalToken0 = 0;
        uint256 totalToken1 = 0;

        for (uint256 i = 0; i < weights.length; i++) {
            (uint256 t0, uint256 t1) = _processAndLogRange(p, i);
            totalToken0 += t0;
            totalToken1 += t1;
        }

        console2.log("--------------------------------------------------------------------------------");
        console2.log("  # = Token0 (right of center), = = Token1 (left of center)");
        console2.log("");
        console2.log("  TOTALS:");
        console2.log("    Token0 value: ", _formatValue(totalToken0));
        console2.log("    Token1 value: ", _formatValue(totalToken1));
        console2.log("    Total:        ", _formatValue(totalToken0 + totalToken1));
    }

    function _processAndLogRange(TokenVizParams memory p, uint256 i) internal pure returns (uint256 token0, uint256 token1) {
        uint256 TOTAL_VALUE = 100e18;
        uint256 rangeValue = FullMath.mulDiv(TOTAL_VALUE, p.weights[i], 1e18);

        // Determine token split based on position relative to centerTick
        if (p.upperTicks[i] <= p.centerTick) {
            // Entirely left of center = all Token1
            token1 = rangeValue;
        } else if (p.lowerTicks[i] >= p.centerTick) {
            // Entirely right of center = all Token0
            token0 = rangeValue;
        } else {
            // Straddles center = split 50/50
            token0 = rangeValue / 2;
            token1 = rangeValue / 2;
        }

        string memory bar = _createTokenBar(token0, token1, p.maxWeight, p.weights[i], 40);
        string memory marker = (i == p.centerIdx) ? " *" : "";
        uint256 pct = p.maxWeight > 0 ? (p.weights[i] * 100) / p.maxWeight : 0;

        console2.log(
            string(
                abi.encodePacked(
                    "[", _int24ToString(p.lowerTicks[i]), ",", _int24ToString(p.upperTicks[i]), "]: ",
                    bar,
                    " ", _uint256ToString(pct), "% | T0:", _formatValue(token0), " T1:", _formatValue(token1),
                    marker
                )
            )
        );
    }

    function _createTokenBar(uint256 token0, uint256 token1, uint256 maxWeight, uint256 weight, uint256 maxLen)
        internal pure returns (string memory)
    {
        if (maxWeight == 0) return "";
        uint256 totalBarLen = (weight * maxLen) / maxWeight;
        if (totalBarLen == 0 && weight > 0) totalBarLen = 1;

        uint256 totalValue = token0 + token1;
        if (totalValue == 0) return "";

        uint256 token0Len = (token0 * totalBarLen) / totalValue;
        uint256 token1Len = totalBarLen - token0Len;

        bytes memory bar = new bytes(totalBarLen);
        for (uint256 j = 0; j < token0Len; j++) {
            bar[j] = "#";
        }
        for (uint256 j = token0Len; j < totalBarLen; j++) {
            bar[j] = "=";
        }
        return string(bar);
    }

    function _formatValue(uint256 value) internal pure returns (string memory) {
        uint256 whole = value / 1e18;
        uint256 decimal = (value % 1e18) / 1e16;
        if (whole == 0 && decimal == 0 && value > 0) return "0.01";
        return string(abi.encodePacked(
            _uint256ToString(whole), ".",
            decimal < 10 ? "0" : "",
            _uint256ToString(decimal)
        ));
    }

    function _int24ToString(int24 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        bool negative = value < 0;
        uint256 absValue = negative ? uint256(uint24(-value)) : uint256(uint24(value));

        bytes memory buffer = new bytes(10);
        uint256 i = buffer.length;

        while (absValue > 0) {
            i--;
            buffer[i] = bytes1(uint8(48 + absValue % 10));
            absValue /= 10;
        }

        if (negative) {
            i--;
            buffer[i] = bytes1("-");
        }

        bytes memory result = new bytes(buffer.length - i);
        for (uint256 j = 0; j < result.length; j++) {
            result[j] = buffer[i + j];
        }
        return string(result);
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        bytes memory buffer = new bytes(20);
        uint256 i = buffer.length;

        while (value > 0) {
            i--;
            buffer[i] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }

        bytes memory result = new bytes(buffer.length - i);
        for (uint256 j = 0; j < result.length; j++) {
            result[j] = buffer[i + j];
        }
        return string(result);
    }

    /**
     * @notice Helper to calculate densities (avoids stack too deep)
     */
    function _calculateDensities(
        int24[] memory lowerTicks,
        int24[] memory upperTicks,
        int24 centerTick,
        uint24 ticksLeft,
        uint24 ticksRight,
        int24 tickSpacing
    ) internal view returns (uint256[] memory) {
        return strategy.calculateDensities(
            lowerTicks,
            upperTicks,
            centerTick, // currentTick
            centerTick, // centerTick
            ticksLeft,
            ticksRight,
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            tickSpacing,
            true    // useAssetWeights
        );
    }
}
