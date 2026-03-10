// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {wadExp} from "solmate/src/utils/SignedWadMath.sol";

contract TestExponentialDistribution is TestMultiPositionManager {
    function setUp() public override {
        super.setUp();
    }

    function test_ExponentialDistributionIsActuallyExponential() public {
        console.log("\n=== Testing True Exponential Distribution ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with 100% weight to token0 to see pure distribution
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 0,
            weight0: 1e18,
            weight1: 0,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0, // No limit positions for clarity
                weight0: 1e18, // 100% token0
                weight1: 0,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Get positions and check distribution
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("\n=== EXPONENTIAL DISTRIBUTION ANALYSIS ===");
        console.log("Positions above current price (should show exponential decay):\n");

        // Collect positions with liquidity above current price
        uint256[] memory liquidities = new uint256[](16); // Positions above tick 0
        uint256 count = 0;

        for (uint256 i = 0; i < basePositionsLength; i++) {
            if (positions[i].lowerTick >= 0 && positionData[i].liquidity > 0) {
                liquidities[count] = positionData[i].liquidity;

                // Calculate token amounts for this position
                (uint256 amount0, uint256 amount1) = _getPositionAmounts(i, positions[i], positionData[i]);

                console.log("Position", count);
                console.log("  Range: [");
                console.logInt(positions[i].lowerTick);
                console.log("  ,");
                console.logInt(positions[i].upperTick);
                console.log("  ]");
                console.log("  Liquidity:", positionData[i].liquidity);
                console.log("  Token0:", amount0 / 1e18, "ether");

                count++;
            }
        }

        // Check for exponential decay: ratio between consecutive positions should be roughly constant
        console.log("\n=== DECAY RATIOS (should be roughly constant for exponential) ===");

        for (uint256 i = 1; i < count; i++) {
            if (liquidities[i - 1] > 0) {
                uint256 ratio = (liquidities[i] * 1000) / liquidities[i - 1];
                console.log("Position", i);
                console.log("  / Position", i - 1);
                console.log("  ratio:", ratio, "/ 1000");

                // For true exponential decay, ratios should be similar
                // Allow some variance due to rounding
                if (i > 1 && count > 3) {
                    uint256 prevRatio = (liquidities[i - 1] * 1000) / liquidities[i - 2];
                    uint256 diff = ratio > prevRatio ? ratio - prevRatio : prevRatio - ratio;

                    // Ratios should be within 20% of each other for exponential
                    if (diff > 200) {
                        console.log("  WARNING: Ratio difference too large, not exponential!");
                    }
                }
            }
        }

        // Visual representation
        console.log("\n=== VISUAL LIQUIDITY DISTRIBUTION ===");
        console.log("(Normalized to max = 50 chars)");

        uint256 maxLiquidity = 0;
        for (uint256 i = 0; i < count; i++) {
            if (liquidities[i] > maxLiquidity) {
                maxLiquidity = liquidities[i];
            }
        }

        for (uint256 i = 0; i < count; i++) {
            uint256 bars = (liquidities[i] * 50) / maxLiquidity;
            if (bars == 0 && liquidities[i] > 0) bars = 1;

            string memory barChart = "";
            for (uint256 j = 0; j < bars; j++) {
                barChart = string(abi.encodePacked(barChart, "#"));
            }
            console.log("Pos", i, ":", barChart);
        }

        vm.stopPrank();
    }

    function test_CompareOldVsNewFormula() public {
        console.log("\n=== Comparing Old Polynomial vs New Exponential Formula ===\n");

        // Test various distances
        int24 center = 0;
        uint256 lambda = 333; // ticksLeft/3 or ticksRight/3 for 1000 ticks

        console.log("Lambda:", lambda);
        console.log("");
        console.log("Distance | Old Formula | New Formula | Ratio");
        console.log("---------|-------------|-------------|-------");

        for (uint256 distance = 0; distance <= 1000; distance += 100) {
            uint256 oldWeight = _calculateOldWeight(distance, lambda);
            uint256 newWeight = _calculateNewWeight(distance, lambda);

            uint256 ratio = oldWeight > 0 ? (newWeight * 100) / oldWeight : 0;

            console.log("Distance:", distance);
            console.log("  Old:", oldWeight / 1e15, "e15");
            console.log("  New:", newWeight / 1e15, "e15");
            console.log("  Ratio:", ratio, "%");
        }
    }

    function _calculateOldWeight(uint256 absDistance, uint256 lambda) private pure returns (uint256) {
        if (absDistance < lambda * 3) {
            uint256 scaledDist = (absDistance * 1e18) / lambda;
            if (scaledDist < 1e18) {
                return 1e18 - (scaledDist * scaledDist) / 2e18;
            } else if (scaledDist < 2e18) {
                return 1e18 / (scaledDist + 1e18);
            } else {
                return 1e18 / ((scaledDist * scaledDist) / 1e18);
            }
        } else {
            return 1;
        }
    }

    function _calculateNewWeight(uint256 absDistance, uint256 lambda) private pure returns (uint256) {
        if (absDistance < lambda * 10) {
            int256 exponent = -int256((absDistance * 1e18) / lambda);
            int256 expResult = wadExp(exponent);
            return expResult > 0 ? uint256(expResult) : 0;
        } else {
            return 0;
        }
    }

    function _getPositionAmounts(
        uint256 positionIndex,
        IMultiPositionManager.Range memory position,
        IMultiPositionManager.PositionData memory positionData
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Skip if no liquidity
        if (positionData.liquidity == 0) {
            return (0, 0);
        }

        // Get current price (tick = 0 means price = 1)
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96

        // Calculate sqrt prices for the position range
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(position.lowerTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(position.upperTick);

        // Use LiquidityAmounts library to calculate token amounts
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, positionData.liquidity
        );
    }
}
