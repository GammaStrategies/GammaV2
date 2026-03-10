// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";

contract TestCarpetedStrategies is TestMultiPositionManager {
    // The unified strategies in the parent already support carpet functionality
    // We'll create additional strategy instances for testing specific carpet behavior
    GaussianStrategy carpetedGaussian;
    UniformStrategy carpetedUniform;
    ExponentialStrategy carpetedExponential;

    function setUp() public override {
        super.setUp();

        // Create additional strategy instances for carpet-specific testing
        carpetedGaussian = new GaussianStrategy();
        carpetedUniform = new UniformStrategy();
        carpetedExponential = new ExponentialStrategy();

        // Note: These are not registered in any registry as they're used directly
        // for unit testing strategy behavior, not through MultiPositionManager
        // The parent's registry and strategies are used for inherited tests
    }

    function test_CarpetedGaussianGenerateRanges() public {
        console.log("Testing CarpetedGaussianStrategy range generation...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedGaussian.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        console.log("Generated", lowerTicks.length, "ranges");

        // Check for full-range floor position at extremes
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        bool hasFloor = false;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        console.log("Has full-range floor:", hasFloor);

        // Should have full-range floor position
        assertTrue(hasFloor, "Should have a full-range floor position");

        // Display ranges
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            console.log("Range", i);
            console.logInt(lowerTicks[i]);
            console.logInt(upperTicks[i]);
        }
    }

    function test_CarpetedGaussianWeights() public {
        console.log("Testing CarpetedGaussianStrategy weight distribution...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedGaussian.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        uint256[] memory weights = carpetedGaussian.calculateDensities(
            lowerTicks,
            upperTicks,
            0, // current tick
            centerTick,
            ticksLeft,
            ticksRight,
            0.5e18, // weight0 (50%)
            0.5e18, // weight1 (50%)
            true, // useCarpet=true
            tickSpacing,
            false // useAssetWeights=false (explicit 50/50)
        );

        // Check full-range floor has zero weight
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        uint256 totalWeight = 0;
        uint256 floorWeight = 0;
        bool hasFloor = false;

        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];

            // Identify full-range floor position
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                floorWeight = weights[i];
                console.log("Full-range floor position", i);
                console.log("weight:", weights[i] * 100 / 1e18);
            }
        }

        console.log("Floor weight (basis points):", floorWeight * 10000 / 1e18);
        assertTrue(hasFloor, "Full-range floor should be present");
        assertEq(floorWeight, 0, "Full-range floor weight should be 0");

        // Verify total weight sums to 1
        assertApproxEqAbs(totalWeight, 1e18, 1e15, "Total weight should sum to 1");
    }

    function test_CarpetedUniformGenerateRanges() public {
        console.log("Testing CarpetedUniformStrategy range generation...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedUniform.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        console.log("Generated", lowerTicks.length, "ranges");

        // Check for full-range floor position
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        bool hasFloor = false;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        assertTrue(hasFloor, "Should have a full-range floor position");

        // Check uniform spacing in base ranges
        uint256 startIdx = hasFloor ? 1 : 0;
        uint256 endIdx = lowerTicks.length;

        if (endIdx - startIdx > 1) {
            int24 expectedWidth = upperTicks[startIdx] - lowerTicks[startIdx];
            console.log("Expected uniform width:", expectedWidth);

            for (uint256 i = startIdx + 1; i < endIdx; i++) {
                int24 width = upperTicks[i] - lowerTicks[i];
                // Allow some variation due to rounding
                assertApproxEqAbs(
                    uint256(uint24(width)),
                    uint256(uint24(expectedWidth)),
                    uint256(uint24(tickSpacing * 2)),
                    "Ranges should have similar widths"
                );
            }
        }
    }

    function test_CarpetedUniformWeights() public {
        console.log("Testing CarpetedUniformStrategy weight distribution...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedUniform.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        uint256[] memory weights = carpetedUniform.calculateDensities(
            lowerTicks,
            upperTicks,
            0,
            centerTick,
            ticksLeft,
            ticksRight,
            0.5e18, // weight0 (50%)
            0.5e18, // weight1 (50%)
            true, // useCarpet=true
            tickSpacing,
            false // useAssetWeights=false (explicit 50/50)
        );

        // Identify floor vs base positions
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        uint256 floorWeight = 0;
        uint256 baseWeight = 0;
        uint256 numBaseRanges = 0;

        for (uint256 i = 0; i < weights.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                floorWeight += weights[i];
            } else {
                baseWeight += weights[i];
                numBaseRanges++;
            }
        }

        console.log("Floor weight (basis points):", floorWeight * 10000 / 1e18);
        console.log("Base weight per range (basis points):", baseWeight / numBaseRanges * 10000 / 1e18);

        // Verify floor has zero weight
        assertEq(floorWeight, 0, "Full-range floor should have zero weight");

        // Verify base ranges have uniform weights
        if (numBaseRanges > 0) {
            uint256 expectedBaseWeight = 1e18 / numBaseRanges;
            for (uint256 i = 0; i < weights.length; i++) {
                if (!(lowerTicks[i] == minUsable && upperTicks[i] == maxUsable)) {
                    assertApproxEqAbs(weights[i], expectedBaseWeight, 1e15, "Base ranges should have uniform weights");
                }
            }
        }
    }

    function test_CarpetedExponentialGenerateRanges() public {
        console.log("Testing CarpetedExponentialStrategy range generation...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedExponential.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        console.log("Generated", lowerTicks.length, "ranges");

        // Check for full-range floor position
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        bool hasFloor = false;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        assertTrue(hasFloor, "Should have a full-range floor position");

        // Display ranges to verify exponential spacing
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            int24 width = upperTicks[i] - lowerTicks[i];
            console.log("Range", i);
            console.log("Width:", uint256(uint24(width)));
        }
    }

    function test_CarpetedExponentialWeights() public {
        console.log("Testing CarpetedExponentialStrategy weight distribution...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;
        int24 tickSpacing = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = carpetedExponential.generateRanges(
            centerTick,
            ticksLeft,
            ticksRight,
            tickSpacing,
            true // useCarpet=true to generate carpet positions
        );

        uint256[] memory weights = carpetedExponential.calculateDensities(
            lowerTicks,
            upperTicks,
            0,
            centerTick,
            ticksLeft,
            ticksRight,
            0.5e18, // weight0 (50%)
            0.5e18, // weight1 (50%)
            true, // useCarpet=true
            tickSpacing,
            false // useAssetWeights=false (explicit 50/50)
        );

        // Check full-range floor weight
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        uint256 floorWeight = 0;
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                floorWeight += weights[i];
            }
        }

        console.log("Floor weight (basis points):", floorWeight * 10000 / 1e18);

        // Verify floor weight
        assertEq(floorWeight, 0, "Full-range floor should have zero weight");
        assertApproxEqAbs(totalWeight, 1e18, 1e15, "Total weight should sum to 1");

        // Verify exponential decay from center
        uint256 startIdx = (lowerTicks[0] == minUsable && upperTicks[0] == maxUsable) ? 1 : 0;
        uint256 endIdx = weights.length;

        if (endIdx - startIdx > 2) {
            // Find position closest to center
            uint256 maxWeight = 0;
            uint256 maxWeightIdx = startIdx;

            for (uint256 i = startIdx; i < endIdx; i++) {
                if (weights[i] > maxWeight) {
                    maxWeight = weights[i];
                    maxWeightIdx = i;
                }
            }

            console.log("Max weight position:", maxWeightIdx);
            console.log("Weight percent:", maxWeight * 100 / 1e18);

            // Verify weights decrease as we move away from max
            if (maxWeightIdx > startIdx) {
                assertTrue(weights[maxWeightIdx] > weights[startIdx], "Center should have more weight than edges");
            }
            if (maxWeightIdx < endIdx - 1) {
                assertTrue(weights[maxWeightIdx] > weights[endIdx - 1], "Center should have more weight than edges");
            }
        }
    }

    function test_CompareStrategies() public {
        console.log("Comparing all carpeted strategies...");

        // Generate ranges for Gaussian strategy
        (int24[] memory gaussianLowers, int24[] memory gaussianUppers) = carpetedGaussian.generateRanges(
            0,
            1200,
            1200,
            60,
            true // useCarpet=true
        );

        console.log("Gaussian ranges:", gaussianLowers.length);

        // Get weights for Gaussian
        uint256[] memory gaussianWeights = carpetedGaussian.calculateDensities(
            gaussianLowers,
            gaussianUppers,
            0,
            0,
            1200,
            1200,
            0.5e18,
            0.5e18, // weight0, weight1 (50% each)
            true, // useCarpet=true
            60, // tickSpacing
            false // useAssetWeights=false (explicit 50/50)
        );

        // Calculate floor weight
        uint256 gaussianFloor = 0;
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        for (uint256 i = 0; i < gaussianWeights.length; i++) {
            if (gaussianLowers[i] == minUsable && gaussianUppers[i] == maxUsable) {
                gaussianFloor += gaussianWeights[i];
            }
        }

        console.log("Gaussian floor weight (basis points):", gaussianFloor * 10000 / 1e18);

        // Floor weight should be zero
        assertEq(gaussianFloor, 0, "Gaussian floor should have zero weight");
    }
}
