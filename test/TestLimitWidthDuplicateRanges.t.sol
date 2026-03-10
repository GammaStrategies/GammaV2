// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./TestCarpetedEdgeCases.t.sol";

import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract TestLimitWidthDuplicateRanges is TestCarpetedEdgeCases {
    function test_LimitWidthCanCreateDuplicateRanges() public {
        console.log("\n=== Testing potential duplicate ranges with limitWidth ===\n");

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

        // Current tick is 0, so limit positions with limitWidth=120 would be:
        // Lower limit: [-120, 0]
        // Upper limit: [60, 180]

        // Let's check what ranges the strategies generate
        PoolKey memory poolKey = multiPositionManager.poolKey();
        int24 tickSpacing = poolKey.tickSpacing;

        // Check Exponential strategy ranges
        (int24[] memory lowerTicks, int24[] memory upperTicks) = exponentialStrategy.generateRanges(
            0, // centerTick
            120, // ticksLeft - deliberately small to potentially overlap
            120, // ticksRight - deliberately small to potentially overlap
            tickSpacing,
            false
        );

        console.log("Exponential strategy ranges:");
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            console.log("Range", i);
            console.logInt(lowerTicks[i]);
            console.logInt(upperTicks[i]);

            // Check if this would conflict with limit positions
            if (lowerTicks[i] == -120 && upperTicks[i] == 0) {
                console.log("  [CONFLICT] This matches lower limit position!");
            }
            if (lowerTicks[i] == 60 && upperTicks[i] == 180) {
                console.log("  [CONFLICT] This matches upper limit position!");
            }
        }

        // Try to rebalance with limitWidth - this might fail due to duplicates
        console.log("\nAttempting rebalance with limitWidth=120...");

        (uint256[2][] memory outMinLWDR1, uint256[2][] memory inMinLWDR1) =         SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            120,
            120,
            120,
            0.5e18,
            0.5e18,
            false,
            false,
            500,
            500
        );

        vm.prank(owner);
        try multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 120, // ticksLeft - small range
                tRight: 120, // ticksRight - small range
                limitWidth: 120, // limitWidth - will create [-120,0] and [60,180]
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinLWDR1,
            inMinLWDR1
        ) {
            console.log("[SUCCESS] Rebalance succeeded - no duplicate ranges", false);

            // Check what positions were created
            (IMultiPositionManager.Range[] memory positions,) = multiPositionManager.getPositions();

            console.log("Total positions created:", positions.length);
            for (uint256 i = 0; i < positions.length; i++) {
                console.log("Position", i);
                console.logInt(positions[i].lowerTick);
                console.logInt(positions[i].upperTick);
            }
        } catch Error(string memory reason) {
            console.log("[FAILED] Rebalance failed with:", reason);
        } catch (bytes memory data) {
            // Try to decode DuplicatedRange error
            if (data.length >= 4) {
                bytes4 selector = bytes4(data);
                if (selector == RebalanceLogic.DuplicatedRange.selector) {
                    console.log("[FAILED] Rebalance failed due to duplicate ranges!");
                    // The error includes the duplicate range
                    (IMultiPositionManager.Range memory duplicateRange) =
                        abi.decode(_slice(data, 4, data.length - 4), (IMultiPositionManager.Range));
                    console.log("Duplicate range:");
                    console.logInt(duplicateRange.lowerTick);
                    console.logInt(duplicateRange.upperTick);
                } else {
                    console.log("[FAILED] Rebalance failed with unknown error");
                }
            }
        }
    }

    function test_LimitWidthWithCarpetedStrategy() public {
        console.log("\n=== Testing limitWidth with carpeted strategy ===\n");

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

        // Check what ranges carpeted Gaussian generates
        PoolKey memory poolKey = multiPositionManager.poolKey();
        int24 tickSpacing = poolKey.tickSpacing;

        (int24[] memory lowerTicks, int24[] memory upperTicks) = exponentialStrategy.generateRanges(
            0, // centerTick
            1200, // ticksLeft
            1200, // ticksRight,
            tickSpacing,
            false
        );

        console.log("Exponential strategy ranges:");
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            console.log("Range", i);
            console.logInt(lowerTicks[i]);
            console.logInt(upperTicks[i]);
        }

        // Try with a limitWidth that might create conflicts
        console.log("\nAttempting rebalance with limitWidth=600...");

        (uint256[2][] memory outMinLWDR2, uint256[2][] memory inMinLWDR2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            1200,
            1200,
            600,
            0.5e18,
            0.5e18,
            false,
            false,
            500,
            500
        );

        vm.prank(owner);
        try multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 1200, // ticksLeft
                tRight: 1200, // ticksRight,
                limitWidth: 600, // limitWidth - will create [-600,0] and [60,660]
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinLWDR2,
            inMinLWDR2
        ) {
            console.log("[SUCCESS] Rebalance succeeded", false);

            (IMultiPositionManager.Range[] memory positions,) = multiPositionManager.getPositions();

            console.log("Total positions:", positions.length);

            // Check if we have the expected limit positions
            uint256 basePositionsLength = multiPositionManager.basePositionsLength();
            console.log("Base positions:", basePositionsLength);
            console.log("Limit positions:", positions.length - basePositionsLength);

            if (positions.length > basePositionsLength) {
                console.log("\nLimit positions:");
                for (uint256 i = basePositionsLength; i < positions.length; i++) {
                    console.log("Limit position", i - basePositionsLength);
                    console.logInt(positions[i].lowerTick);
                    console.logInt(positions[i].upperTick);
                }
            }
        } catch (bytes memory data) {
            if (data.length >= 4) {
                bytes4 selector = bytes4(data);
                if (selector == RebalanceLogic.DuplicatedRange.selector) {
                    console.log("[FAILED] Duplicate range detected!");
                    (IMultiPositionManager.Range memory duplicateRange) =
                        abi.decode(_slice(data, 4, data.length - 4), (IMultiPositionManager.Range));
                    console.log("Duplicate range:");
                    console.logInt(duplicateRange.lowerTick);
                    console.logInt(duplicateRange.upperTick);
                } else {
                    console.log("[FAILED] Rebalance failed");
                }
            }
        }
    }

    // Helper function to slice bytes
    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory) {
        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
        return result;
    }
}
