// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./TestCarpetedEdgeCases.t.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract TestDuplicateRangeScenario is TestCarpetedEdgeCases {
    function test_DuplicateRangeWithUniformStrategy() public {
        console.log("\n=== Testing duplicate range scenario with UniformStrategy ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        // Get tick spacing
        PoolKey memory poolKey = multiPositionManager.poolKey();
        int24 tickSpacing = poolKey.tickSpacing;
        console.log("Tick spacing:", uint256(uint24(tickSpacing)));

        // ExponentialStrategy with very tight range might create a position like [-60, 0]
        // which would overlap with limit position [-120, 0]
        (int24[] memory lowerTicks, int24[] memory upperTicks) = exponentialStrategy.generateRanges(
            0, // centerTick
            60, // ticksLeft - very small
            60, // ticksRight - very small
            tickSpacing,
            false
        );

        console.log("Exponential strategy ranges:");
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            console.log("Range", i);
            console.logInt(lowerTicks[i]);
            console.logInt(upperTicks[i]);
        }

        // Limit positions with limitWidth=120 would be:
        // Lower: [-120, 0]
        // Upper: [60, 180]
        console.log("\nLimit positions would be:");
        console.log("Lower limit: [-120, 0]");
        console.log("Upper limit: [60, 180]");

        // Check for potential conflicts
        bool hasConflict = false;
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            if (lowerTicks[i] == -120 && upperTicks[i] == 0) {
                console.log("[CONFLICT] Range", i, "matches lower limit!");
                hasConflict = true;
            }
            if (lowerTicks[i] == 60 && upperTicks[i] == 180) {
                console.log("[CONFLICT] Range", i, "matches upper limit!");
                hasConflict = true;
            }
        }

        if (hasConflict) {
            console.log("\nAttempting rebalance - expecting DuplicatedRange error...");

            (uint256[2][] memory outMinDRS1, uint256[2][] memory inMinDRS1) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 60,
            ticksRight: 60,
            limitWidth: 120,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(RebalanceLogic.DuplicatedRange.selector, IMultiPositionManager.Range(-120, 0))
            );
            multiPositionManager.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(exponentialStrategy),
                    center: 0, // centerTick
                    tLeft: 60, // ticksLeft
                    tRight: 60, // ticksRight,
                    limitWidth: 120, // limitWidth
                    weight0: 0.5e18,
                    weight1: 0.5e18,
                    useCarpet: false
                }),
                outMinDRS1,
                inMinDRS1
            );

            console.log("[EXPECTED] Rebalance reverted with DuplicatedRange");
        } else {
            console.log("\nNo conflicts detected - rebalance should succeed");

            (uint256[2][] memory outMinDRS2, uint256[2][] memory inMinDRS2) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 60,
            ticksRight: 60,
            limitWidth: 120,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            vm.prank(owner);
            multiPositionManager.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(exponentialStrategy),
                    center: 0, // centerTick
                    tLeft: 60, // ticksLeft
                    tRight: 60, // ticksRight,
                    limitWidth: 120, // limitWidth
                    weight0: 0.5e18,
                    weight1: 0.5e18,
                    useCarpet: false
                }),
                outMinDRS2,
                inMinDRS2
            );

            console.log("[SUCCESS] Rebalance succeeded");
        }
    }

    function test_ShouldAdjustLimitWidthToAvoidDuplicates() public {
        console.log("\n=== Proposal: Adjust limitWidth to avoid duplicates ===\n");

        // This test demonstrates the user's suggestion:
        // If limit ranges overlap with base ranges, increase limitWidth by tickSpacing

        // Deposit
        vm.startPrank(owner);
        token0.mint(owner, 1e20);
        token1.mint(owner, 1e20);
        token0.approve(address(multiPositionManager), 1e20);
        token1.approve(address(multiPositionManager), 1e20);
        multiPositionManager.deposit(1e20, 1e20, owner, owner);
        vm.stopPrank();

        PoolKey memory poolKey2 = multiPositionManager.poolKey();
        int24 tickSpacing = poolKey2.tickSpacing;

        // Test different limitWidth values
        int24[] memory testWidths = new int24[](3);
        testWidths[0] = 60; // Might conflict
        testWidths[1] = 120; // Might conflict
        testWidths[2] = 180; // Less likely to conflict

        for (uint256 w = 0; w < testWidths.length; w++) {
            uint24 limitWidth = uint24(testWidths[w]);
            console.log("\nTesting limitWidth =", uint256(limitWidth));

            // Calculate what the limit positions would be
            int24 lowerLimitStart = -int24(limitWidth);
            int24 lowerLimitEnd = 0;
            int24 upperLimitStart = tickSpacing;
            int24 upperLimitEnd = tickSpacing + int24(limitWidth);

            console.log("Would create limit positions:");
            console.log("  Lower limit range:");
            console.logInt(lowerLimitStart);
            console.logInt(lowerLimitEnd);
            console.log("  Upper limit range:");
            console.logInt(upperLimitStart);
            console.logInt(upperLimitEnd);

            // Check if exponential strategy with range 60 would conflict
            (int24[] memory lowerTicks, int24[] memory upperTicks) =
                exponentialStrategy.generateRanges(0, 60, 60, tickSpacing, false);

            bool wouldConflict = false;
            for (uint256 i = 0; i < lowerTicks.length; i++) {
                if (
                    (lowerTicks[i] == lowerLimitStart && upperTicks[i] == lowerLimitEnd)
                        || (lowerTicks[i] == upperLimitStart && upperTicks[i] == upperLimitEnd)
                ) {
                    wouldConflict = true;
                    console.log("  [CONFLICT] Base range would overlap:");
                    console.logInt(lowerTicks[i]);
                    console.logInt(upperTicks[i]);
                    break;
                }
            }

            if (wouldConflict) {
                console.log("  Suggestion: Increase limitWidth by", uint256(uint24(tickSpacing)), "to avoid conflict");
                int24 adjustedWidth = int24(limitWidth) + tickSpacing;
                console.log("  Adjusted limitWidth would be:", uint256(uint24(adjustedWidth)));
            } else {
                console.log("  No conflicts detected");
            }
        }
    }
}
