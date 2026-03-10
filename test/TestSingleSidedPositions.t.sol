// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./TestSingleSidedWeights.t.sol";

contract TestSingleSidedPositions is TestSingleSidedWeights {
    function test_SingleSidedPositionsBehavior() public {
        console.log("\n=== Testing Single-Sided Positions Behavior ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with 100% weight to token0 (no limit positions for this test)
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
                limitWidth: 0, // No limit positions
                weight0: 1e18, // 100% token0
                weight1: 0, // 0% token1
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Get positions and verify behavior
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("\n=== DETAILED POSITION ANALYSIS ===");
        console.log("Current tick: 0");
        console.log("Total base positions:", basePositionsLength);
        console.log("----------------------------------------");

        // Get token amounts for each position
        for (uint256 i = 0; i < basePositionsLength; i++) {
            // Calculate token amounts in this position
            (uint256 amount0, uint256 amount1) = _getPositionAmounts(i, positions[i], positionData[i]);

            console.log("\nPosition", i);
            console.log("  Range: [");
            console.logInt(positions[i].lowerTick);
            console.log("  ,");
            console.logInt(positions[i].upperTick);
            console.log("  ]");
            console.log("  Liquidity:", positionData[i].liquidity);
            console.log("  Token0:", amount0 / 1e18, "ether");
            console.log("  Token1:", amount1 / 1e18, "ether");

            // Categorize position relative to current price
            if (positions[i].upperTick <= 0) {
                console.log("  Type: BELOW current price (needs token1)");
            } else if (positions[i].lowerTick >= 0) {
                console.log("  Type: ABOVE current price (needs token0)");
            } else {
                console.log("  Type: SPANS current price (needs both)");
            }

            // Visual representation of liquidity
            if (positionData[i].liquidity > 0) {
                uint256 bars = (positionData[i].liquidity * 50) / 1e22; // Scale for visualization
                if (bars == 0 && positionData[i].liquidity > 0) bars = 1;
                if (bars > 50) bars = 50;

                string memory barChart = "  Liquidity: [";
                for (uint256 j = 0; j < bars; j++) {
                    barChart = string(abi.encodePacked(barChart, "#"));
                }
                console.log(barChart, "]");
            } else {
                console.log("  Liquidity: [EMPTY]");
            }
        }

        console.log("\n=== POSITION DISTRIBUTION SUMMARY ===");

        // Count positions by type
        uint256 positionsWithLiquidity = 0;
        uint256 emptyPositions = 0;
        uint256 belowCurrentPrice = 0;
        uint256 aboveCurrentPrice = 0;
        uint256 spanningCurrentPrice = 0;

        for (uint256 i = 0; i < basePositionsLength; i++) {
            if (positionData[i].liquidity > 0) {
                positionsWithLiquidity++;
            } else {
                emptyPositions++;
            }

            if (positions[i].upperTick <= 0) {
                belowCurrentPrice++;
            } else if (positions[i].lowerTick >= 0) {
                aboveCurrentPrice++;
            } else {
                spanningCurrentPrice++;
            }
        }

        console.log("  Positions with liquidity:", positionsWithLiquidity);
        console.log("  Empty positions:", emptyPositions);
        console.log("  Positions below current price:", belowCurrentPrice);
        console.log("  Positions above current price:", aboveCurrentPrice);
        console.log("  Positions spanning current price:", spanningCurrentPrice);

        // Verify that some positions are empty (those needing token1)
        assertTrue(emptyPositions > 0, "Should have empty positions");
        assertTrue(positionsWithLiquidity > 0, "Should have positions with liquidity");

        // Check total amounts to verify capital is allocated
        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        console.log("\nTotal amounts in positions:");
        console.log("  Token0:", total0 / 1e18, "ether");
        console.log("  Token1:", total1 / 1e18, "ether");

        // With 100% weight to token0, we expect:
        // - Significant token0 in positions (those above current price)
        // - Token1 only in positions that span the current price (minimal)
        assertGt(total0, 50 ether, "Should have significant token0 in positions");
        // Note: Some token1 is still used in positions that span current price
        console.log("Token1 in positions is expected due to positions spanning current price");

        vm.stopPrank();
    }

    function _getPositionAmounts(
        uint256 positionIndex,
        IMultiPositionManager.Range memory position,
        IMultiPositionManager.PositionData memory positionData
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // Skip if no liquidity
        if (positionData.liquidity == 0) {
            return (0, 0);
        }

        // Get current price (tick = 0 means price = 1)
        int24 currentTick = 0;
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96

        // Calculate sqrt prices for the position range
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(position.lowerTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(position.upperTick);

        // Use LiquidityAmounts library to calculate token amounts
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, positionData.liquidity
        );
    }

    function test_ZeroWeightDoesNotCrash() public {
        console.log("\n=== Testing Zero Weight Edge Cases ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Test various edge cases

        // 1. Both weights zero - should default to 50/50
        // Since this is the first rebalance, we pass empty outMin
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 500,
            ticksRight: 500,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
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
                tLeft: 500,
                tRight: 500,
                limitWidth: 60,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("Successfully rebalanced with 0/0 weights (defaults to 50/50)");

        // 2. Extreme single-sided with limit positions
        (outMin, inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 500,
            ticksRight: 500,
            limitWidth: 120,
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
                tLeft: 500,
                tRight: 500,
                limitWidth: 120,
                weight0: 1e18,
                weight1: 0,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("Successfully rebalanced with 100/0 weights and limit positions");

        vm.stopPrank();
    }
}
