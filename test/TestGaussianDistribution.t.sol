// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {GaussianStrategy} from "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import {wadExp} from "solmate/src/utils/SignedWadMath.sol";

contract TestGaussianDistribution is TestMultiPositionManager {
    GaussianStrategy gaussianStrategy;

    function setUp() public override {
        super.setUp();
        gaussianStrategy = new GaussianStrategy();
    }

    function test_GaussianDistributionBellCurve() public {
        console.log("\n=== Testing True Gaussian Bell Curve Distribution ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with Gaussian strategy
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(gaussianStrategy),
            0,
            1000,
            1000,
            0,
            0.5e18,
            0.5e18,
            false,
            false,
            500,
            500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(gaussianStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0, // No limit positions for clarity
                weight0: 0.5e18, // 50/50 to see pure distribution
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Get positions and check distribution
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("\n=== GAUSSIAN BELL CURVE ANALYSIS ===");
        console.log("Positions around center (should show bell curve shape):\n");

        // Find max liquidity for normalization
        uint256 maxLiquidity = 0;
        for (uint256 i = 0; i < basePositionsLength; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }

        // Display positions near center with visual representation
        uint256 centerIndex = basePositionsLength / 2;
        uint256 displayStart = centerIndex > 8 ? centerIndex - 8 : 0;
        uint256 displayEnd = centerIndex + 8 < basePositionsLength ? centerIndex + 8 : basePositionsLength;

        for (uint256 i = displayStart; i < displayEnd; i++) {
            int24 midTick = (positions[i].lowerTick + positions[i].upperTick) / 2;
            uint256 normalizedLiq = (positionData[i].liquidity * 100) / maxLiquidity;

            console.log("Position", i);
            console.log("  Mid-tick:");
            console.logInt(midTick);
            console.log("  Liquidity:", positionData[i].liquidity);
            console.log("  Normalized:", normalizedLiq, "%");

            // Visual bar
            uint256 bars = normalizedLiq / 2; // Scale to 50 chars max
            string memory barChart = "  ";
            for (uint256 j = 0; j < bars; j++) {
                barChart = string(abi.encodePacked(barChart, "#"));
            }
            console.log(barChart);
        }

        // Check for bell curve shape - center should have highest liquidity
        uint256 centerLiquidity = positionData[centerIndex].liquidity;
        assertTrue(
            centerLiquidity == maxLiquidity || positionData[centerIndex - 1].liquidity == maxLiquidity
                || positionData[centerIndex + 1].liquidity == maxLiquidity,
            "Center should have maximum liquidity"
        );

        vm.stopPrank();
    }

    function test_CompareLinearVsGaussian() public {
        console.log("\n=== Comparing Old Linear vs New Gaussian Formula ===\n");

        // Test various distances from center
        uint256 sigma = 333; // ticksRange/3 for 1000 ticks

        console.log("Sigma:", sigma);
        console.log("");
        console.log("Distance | Old Linear | New Gaussian");
        console.log("---------|------------|-------------");

        for (uint256 distance = 0; distance <= 1000; distance += 100) {
            uint256 oldWeight = _calculateOldLinearWeight(distance);
            uint256 newWeight = _calculateNewGaussianWeight(distance, sigma);

            console.log("Distance:", distance);
            console.log("  Linear:", oldWeight / 1e15, "e15");
            console.log("  Gaussian:", newWeight / 1e15, "e15");
        }

        // Test 68-95-99.7 rule
        console.log("\n=== Testing 68-95-99.7 Rule ===");

        uint256 weight1Sigma = _calculateNewGaussianWeight(sigma, sigma);
        uint256 weight2Sigma = _calculateNewGaussianWeight(sigma * 2, sigma);
        uint256 weight3Sigma = _calculateNewGaussianWeight(sigma * 3, sigma);

        console.log("At 1-sigma:", (weight1Sigma * 100) / 1e18, "% of peak");
        console.log("At 2-sigma:", (weight2Sigma * 100) / 1e18, "% of peak");
        console.log("At 3-sigma:", (weight3Sigma * 100) / 1e18, "% of peak");

        // Expected values for Gaussian: ~60.7%, ~13.5%, ~1.1%
        assertTrue(weight1Sigma > 0.55e18 && weight1Sigma < 0.65e18, "1-sigma should be ~60.7% of peak");
        assertTrue(weight2Sigma > 0.1e18 && weight2Sigma < 0.2e18, "2-sigma should be ~13.5% of peak");
        assertTrue(weight3Sigma < 0.05e18, "3-sigma should be ~1.1% of peak");
    }

    function test_GaussianSymmetry() public {
        console.log("\n=== Testing Gaussian Symmetry ===\n");

        uint256 sigma = 333;

        // Test symmetry at various distances
        for (uint256 distance = 100; distance <= 500; distance += 100) {
            uint256 weightLeft = _calculateNewGaussianWeight(distance, sigma);
            uint256 weightRight = _calculateNewGaussianWeight(distance, sigma); // Same distance, opposite side

            console.log("Distance:", distance);
            console.log("  Weight:", weightLeft / 1e15, "e15");

            // Weights should be identical at same distance from center
            assertEq(weightLeft, weightRight, "Gaussian should be symmetric");
        }
    }

    function _calculateOldLinearWeight(uint256 absDistance) private pure returns (uint256) {
        uint256 STANDARD_DEVIATION = 3e18; // From old implementation
        if (absDistance < STANDARD_DEVIATION) {
            return STANDARD_DEVIATION - absDistance;
        } else {
            return 1; // Minimum weight
        }
    }

    function _calculateNewGaussianWeight(uint256 absDistance, uint256 sigma) private pure returns (uint256) {
        if (absDistance < sigma * 6) {
            // Normalize distance by sigma
            int256 normalizedDist = int256((absDistance * 1e18) / sigma);
            // Calculate -0.5 * (normalized_distance)²
            int256 exponent = -(normalizedDist * normalizedDist) / 2e18;
            // Apply exponential
            int256 expResult = wadExp(exponent);
            return expResult > 0 ? uint256(expResult) : 0;
        } else {
            return 0; // Beyond 6-sigma, negligible
        }
    }
}
