// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract TestTickSpacingFix is Test {
    ExponentialStrategy exponential;
    GaussianStrategy gaussian;
    UniformStrategy uniform;

    function setUp() public {
        exponential = new ExponentialStrategy();
        gaussian = new GaussianStrategy();
        uniform = new UniformStrategy();
    }

    function test_FullRangeFloorWeightsWithCorrectTickSpacing() public {
        int24 tickSpacing = 60;

        // Generate ranges with carpet
        (int24[] memory lowerTicks, int24[] memory upperTicks) = exponential.generateRanges(
            0, // centerTick
            1200, // ticksLeft
            1200, // ticksRight,
            tickSpacing,
            true // useCarpet
        );

        // Calculate densities with correct tick spacing
        uint256[] memory weights = exponential.calculateDensities(
            lowerTicks,
            upperTicks,
            0, // currentTick
            0, // centerTick
            1200, // ticksLeft
            1200, // ticksRight,
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            tickSpacing, // CORRECT tick spacing passed
            false // useAssetWeights=false (explicit 50/50)
        );

        // Check full-range floor exists and has zero weight
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        bool hasFloor = false;
        uint256 floorWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                floorWeight = weights[i];
                console.log("Found full-range floor at index", i, "with weight:", weights[i]);
            }
        }

        assertTrue(hasFloor, "Full-range floor should be present when useCarpet=true");
        assertEq(floorWeight, 0, "Full-range floor weight should be 0");

        // Total weights should sum to 1
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        assertApproxEqAbs(totalWeight, 1e18, 1e15, "Total weight should sum to 1");
    }

    function test_NoCarpetWithoutUseCarpetFlag() public {
        int24 tickSpacing = 60;

        // Generate ranges without carpet
        (int24[] memory lowerTicks, int24[] memory upperTicks) = exponential.generateRanges(
            0, // centerTick
            1200, // ticksLeft
            1200, // ticksRight,
            tickSpacing,
            false // useCarpet = false
        );

        // Verify no full-range floor positions
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        bool hasFloor = false;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] == minUsable && upperTicks[i] == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        assertFalse(hasFloor, "Should not have a full-range floor when useCarpet=false");
    }
}
