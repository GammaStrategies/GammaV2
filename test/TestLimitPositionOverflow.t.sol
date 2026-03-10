// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";

contract TestLimitPositionOverflow is TestMultiPositionManager {
    function test_getTotalAmountsWithLimitPositions() public {
        console.log("\n=== Testing getTotalAmounts with Limit Positions ===\n");

        // Setup: Create lopsided token balance to force limit positions
        uint256 token0Amount = 100 ether;
        uint256 token1Amount = 50 ether; // Half of token0

        // Transfer ownership to alice so she can operate
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);
        token0.mint(alice, token0Amount);
        token1.mint(alice, token1Amount);
        token0.approve(address(multiPositionManager), token0Amount);
        token1.approve(address(multiPositionManager), token1Amount);

        // Deposit the lopsided amounts
        (uint256 shares,,) = multiPositionManager.deposit(token0Amount, token1Amount, alice, alice);
        console.log("Shares received:", shares);
        console.log("Deposited token0:", token0Amount / 1e18, "ether");
        console.log("Deposited token1:", token1Amount / 1e18, "ether");

        // Rebalance to create positions (including limit positions due to imbalance)
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // This will create positions based on the strategy
        // With lopsided balance, it should create limit positions
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 60,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Check if limit positions were created
        (MultiPositionManager.Range[] memory positions, MultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("\n=== Positions After Rebalance ===");
        console.log("Total positions:", positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            console.log("\nPosition", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Liquidity:", positionData[i].liquidity);

            // Check if this is a limit position (positions 20-21 typically)
            if (i >= 20) {
                console.log("  >> This is a LIMIT position");
                if (positionData[i].liquidity > 1e21) {
                    console.log("  >> HIGH LIQUIDITY DETECTED:", positionData[i].liquidity);
                }
            }
        }

        // Now try to call getTotalAmounts - this should fail if limit positions have high liquidity
        console.log("\n=== Calling getTotalAmounts ===");
        console.log("This should fail with arithmetic overflow if limit positions have high liquidity...\n");

        (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1) = multiPositionManager.getTotalAmounts();

        console.log("SUCCESS - getTotalAmounts returned:");
        console.log("  Total token0:", total0);
        console.log("  Total token1:", total1);
        console.log("  Total fee0:", totalFee0);
        console.log("  Total fee1:", totalFee1);

        vm.stopPrank();
    }

    function test_getTotalAmountsWithLimitPositions_ForceHighLiquidity() public {
        console.log("\n=== Testing getTotalAmounts with Forced High Liquidity Limit Positions ===\n");

        // Setup: Create very lopsided token balance to force high liquidity limit positions
        uint256 token0Amount = 1000 ether;
        uint256 token1Amount = 10 ether; // Very lopsided - 100:1 ratio

        // Transfer ownership to alice so she can operate
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);
        token0.mint(alice, token0Amount);
        token1.mint(alice, token1Amount);
        token0.approve(address(multiPositionManager), token0Amount);
        token1.approve(address(multiPositionManager), token1Amount);

        // Deposit the very lopsided amounts
        (uint256 shares,,) = multiPositionManager.deposit(token0Amount, token1Amount, alice, alice);
        console.log("Shares received:", shares);
        console.log("Deposited token0:", token0Amount / 1e18, "ether");
        console.log("Deposited token1:", token1Amount / 1e18, "ether");

        // Rebalance with narrow range to force more into limit positions
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 120,
            ticksRight: 120,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // Use very narrow range to force most liquidity into limit positions
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 120,
                tRight: 120,
                limitWidth: 60,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Check positions
        (MultiPositionManager.Range[] memory positions, MultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("\n=== Positions After Rebalance ===");
        console.log("Total positions:", positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positionData[i].liquidity > 0) {
                console.log("\nPosition", i);
                console.logInt(positions[i].lowerTick);
                console.logInt(positions[i].upperTick);
                console.log("  Liquidity:", positionData[i].liquidity);

                if (i >= positions.length - 2) {
                    console.log("  >> This is a LIMIT position");
                    if (positionData[i].liquidity > 1e21) {
                        console.log("  >> HIGH LIQUIDITY LIMIT POSITION!");
                    }
                }
            }
        }

        // Now try to call getTotalAmounts
        console.log("\n=== Calling getTotalAmounts ===");
        console.log("This should fail with arithmetic overflow if limit positions have high liquidity...\n");

        (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1) = multiPositionManager.getTotalAmounts();

        console.log("SUCCESS - getTotalAmounts returned:");
        console.log("  Total token0:", total0);
        console.log("  Total token1:", total1);
        console.log("  Total fee0:", totalFee0);
        console.log("  Total fee1:", totalFee1);

        vm.stopPrank();
    }
}
