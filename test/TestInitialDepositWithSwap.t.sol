// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/periphery/SimpleLens.sol";
import "../src/MultiPositionManager/periphery/InitialDepositLens.sol";
import {SimpleLensRatioUtils} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensRatioUtils.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";

contract TestInitialDepositWithSwap is TestMultiPositionManager {
    GaussianStrategy gaussianStrategy;
    SingleUniformStrategy uniformStrategy;

    function setUp() public override {
        super.setUp();

        // Deploy additional strategies
        gaussianStrategy = new GaussianStrategy();
        uniformStrategy = new SingleUniformStrategy();
    }

    function test_SingleTokenDeposit_100ETH_0USDC() public {
        console.log("\n=== Test: 100% ETH, 0% USDC ===\n");

        uint256 depositETH = 1 ether;
        uint256 depositUSDC = 0;

        (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            uint256[2][] memory inMin,
            SimpleLensInMin.RebalancePreview memory preview
        ) = initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: type(int24).max, // Use current tick
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0, // Use strategy weights
                weight1: 0,
                useCarpet: false,
                amount0: depositETH,
                amount1: depositUSDC,
                maxSlippageBps: 500
            })
        );

        console.log("Input: 1 ETH, 0 USDC");
        console.log("Swap token0->token1:", swapParams.swapToken0);
        console.log("Swap amount:", swapParams.swapAmount);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);
        console.log("Weight0:", swapParams.weight0);
        console.log("Weight1:", swapParams.weight1);
        console.log("Positions:", preview.ranges.length);
        console.log("InMin length:", inMin.length);

        // Assertions
        assertTrue(swapParams.swapToken0, "Should swap token0 (ETH)");
        assertGt(swapParams.swapAmount, 0, "Should swap some ETH");
        assertLt(swapParams.swapAmount, depositETH, "Should not swap all ETH");
        assertGt(finalAmount0, 0, "Should have ETH remaining");
        assertGt(finalAmount1, 0, "Should have USDC after swap");
        assertEq(swapParams.weight0 + swapParams.weight1, 1e18, "Weights should sum to 1e18");
        assertGt(preview.ranges.length, 0, "Should have positions");
        assertEq(inMin.length, preview.ranges.length, "InMin should match positions");
    }

    function test_SingleTokenDeposit_0ETH_100USDC() public {
        console.log("\n=== Test: 0% ETH, 100% USDC ===\n");

        uint256 depositETH = 0;
        uint256 depositUSDC = 2000e6; // 2000 USDC

        (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            ,
            SimpleLensInMin.RebalancePreview memory preview
        ) = initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: type(int24).max,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: depositETH,
                amount1: depositUSDC,
                maxSlippageBps: 500
            })
        );

        console.log("Input: 0 ETH, 2000 USDC");
        console.log("Swap token0->token1:", swapParams.swapToken0);
        console.log("Swap amount:", swapParams.swapAmount);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);

        // Assertions
        assertFalse(swapParams.swapToken0, "Should swap token1 (USDC)");
        assertGt(swapParams.swapAmount, 0, "Should swap some USDC");
        assertLt(swapParams.swapAmount, depositUSDC, "Should not swap all USDC");
        assertGt(finalAmount0, 0, "Should have ETH after swap");
        assertGt(finalAmount1, 0, "Should have USDC remaining");
        assertGt(preview.ranges.length, 0, "Should have positions");
    }

    function test_ImbalancedDeposit_90_10() public {
        console.log("\n=== Test: Imbalanced 90/10 ===\n");

        uint256 depositETH = 0.9 ether;
        uint256 depositUSDC = 400e6; // ~10% value at $4000/ETH

        (uint256 finalAmount0, uint256 finalAmount1, SimpleLensRatioUtils.SwapParams memory swapParams,,) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: depositETH,
                amount1: depositUSDC,
                maxSlippageBps: 500
            })
        );

        console.log("Input: 0.9 ETH, 400 USDC");
        console.log("Swap amount:", swapParams.swapAmount);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);

        // Should rebalance toward 50/50
        assertGt(swapParams.swapAmount, 0, "Should need to swap");
        assertLt(finalAmount0, depositETH, "Should have less ETH than deposited");
        assertGt(finalAmount1, depositUSDC, "Should have more USDC than deposited");
    }

    function test_BalancedDeposit_NoSwapNeeded() public {
        console.log("\n=== Test: Already Balanced (No Swap) ===\n");

        // First calculate what amounts would be balanced by doing a single token deposit
        (uint256 balancedAmount0, uint256 balancedAmount1, SimpleLensRatioUtils.SwapParams memory swapParams1,,) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: 1 ether,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Balanced amounts calculated:");
        console.log("  Amount0:", balancedAmount0);
        console.log("  Amount1:", balancedAmount1);

        // Now deposit with those final amounts (should need minimal/no swap)
        (uint256 finalAmount0, uint256 finalAmount1, SimpleLensRatioUtils.SwapParams memory swapParams,,) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: balancedAmount0,
                amount1: balancedAmount1,
                maxSlippageBps: 500
            })
        );

        console.log("\nSecond call with balanced amounts:");
        console.log("Input amount0:", balancedAmount0);
        console.log("Input amount1:", balancedAmount1);
        console.log("Swap amount:", swapParams.swapAmount);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);

        // Swap amount should be very small or zero
        // Note: May not be exactly 0 due to rounding in price estimation
        uint256 totalValue = balancedAmount0 + balancedAmount1;
        uint256 swapRatio = (swapParams.swapAmount * 100) / totalValue;
        console.log("Swap ratio (%):", swapRatio);

        assertLt(swapRatio, 10, "Swap should be < 10% of total value for already-balanced deposit");
    }

    function test_CustomWeights_80_20() public {
        console.log("\n=== Test: Custom Weights 80/20 ===\n");

        uint256 depositETH = 1 ether;
        uint256 depositUSDC = 0;

        (uint256 finalAmount0, uint256 finalAmount1, SimpleLensRatioUtils.SwapParams memory swapParams,,) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0.8e18, // Force 80% token0
                weight1: 0.2e18, // Force 20% token1
                useCarpet: false,
                amount0: depositETH,
                amount1: depositUSDC,
                maxSlippageBps: 500
            })
        );

        console.log("Input: 1 ETH, 0 USDC");
        console.log("Custom weights: 80/20");
        console.log("Swap amount:", swapParams.swapAmount);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);
        console.log("Returned weight0:", swapParams.weight0);
        console.log("Returned weight1:", swapParams.weight1);

        // Verify custom weights were used
        assertEq(swapParams.weight0, 0.8e18, "Should use custom weight0");
        assertEq(swapParams.weight1, 0.2e18, "Should use custom weight1");

        // Should swap less than 50/50 case (only need 20% in token1)
        assertGt(finalAmount0, 0.7 ether, "Should keep most ETH (80%)");
    }

    function test_DifferentStrategies_Gaussian() public {
        console.log("\n=== Test: Gaussian Strategy ===\n");

        (,, SimpleLensRatioUtils.SwapParams memory swapParams,, SimpleLensInMin.RebalancePreview memory preview) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: 1 ether,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Gaussian - Positions:", preview.ranges.length);
        console.log("Gaussian - Weight0:", swapParams.weight0);

        assertGt(preview.ranges.length, 1, "Gaussian should create multiple positions");
        assertEq(swapParams.weight0 + swapParams.weight1, 1e18, "Weights should sum to 1");
    }

    function test_DifferentStrategies_Uniform() public {
        console.log("\n=== Test: Uniform Strategy ===\n");

        (,, SimpleLensRatioUtils.SwapParams memory swapParams,, SimpleLensInMin.RebalancePreview memory preview) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: 1 ether,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Uniform - Positions:", preview.ranges.length);
        console.log("Uniform - Weight0:", swapParams.weight0);

        assertEq(preview.ranges.length, 1, "Uniform should create single position");
        assertEq(swapParams.weight0 + swapParams.weight1, 1e18, "Weights should sum to 1");
    }

    function test_DifferentStrategies_Exponential() public {
        console.log("\n=== Test: Exponential Strategy ===\n");

        (,, SimpleLensRatioUtils.SwapParams memory swapParams,, SimpleLensInMin.RebalancePreview memory preview) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(exponentialStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: 1 ether,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Exponential - Positions:", preview.ranges.length);
        console.log("Exponential - Weight0:", swapParams.weight0);

        assertGt(preview.ranges.length, 1, "Exponential should create multiple positions");
        assertEq(swapParams.weight0 + swapParams.weight1, 1e18, "Weights should sum to 1");
    }

    function test_WithCarpet_SingleToken() public {
        console.log("\n=== Test: With Carpet Positions ===\n");

        (,, SimpleLensRatioUtils.SwapParams memory swapParams,, SimpleLensInMin.RebalancePreview memory preview) =
        initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: true, // Enable carpet
                amount0: 1 ether,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("With carpet - Positions:", preview.ranges.length);

        // Should have full-range floor position (min/max tick range)
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            if (preview.ranges[i].lowerTick == minUsable && preview.ranges[i].upperTick == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        console.log("Has full-range floor:", hasFloor);

        assertTrue(hasFloor, "Should have a full-range floor position");
        assertGt(swapParams.swapAmount, 0, "Should still need swap with floor");
    }

    function test_EdgeCase_VerySmallAmount() public {
        console.log("\n=== Test: Very Small Amount ===\n");

        uint256 depositETH = 0.001 ether; // 0.001 ETH

        (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            ,
            SimpleLensInMin.RebalancePreview memory preview
        ) = initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: depositETH,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Small amount - Input:", depositETH);
        console.log("Small amount - Swap:", swapParams.swapAmount);
        console.log("Small amount - Final0:", finalAmount0);
        console.log("Small amount - Final1:", finalAmount1);

        assertGt(swapParams.swapAmount, 0, "Should calculate swap even for small amounts");
        assertGt(preview.ranges.length, 0, "Should have positions");
    }

    function test_EdgeCase_VeryLargeAmount() public {
        console.log("\n=== Test: Very Large Amount ===\n");

        uint256 depositETH = 1000 ether; // 1000 ETH

        (
            uint256 finalAmount0,
            uint256 finalAmount1,
            SimpleLensRatioUtils.SwapParams memory swapParams,
            ,
            SimpleLensInMin.RebalancePreview memory preview
        ) = initialDepositLens.getAmountsForInitialDepositWithSwapAndPreview(
            key,
            SimpleLensInMin.InitialDepositWithSwapParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 0,
                ticksLeft: 1500,
                ticksRight: 1500,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false,
                amount0: depositETH,
                amount1: 0,
                maxSlippageBps: 500
            })
        );

        console.log("Large amount - Input:", depositETH);
        console.log("Large amount - Swap:", swapParams.swapAmount);
        console.log("Large amount - Final0:", finalAmount0);
        console.log("Large amount - Final1:", finalAmount1);

        assertGt(swapParams.swapAmount, 0, "Should calculate swap for large amounts");
        assertGt(preview.ranges.length, 0, "Should have positions");

        // Sanity check: swap should be roughly half for 50/50 strategy
        uint256 swapRatio = swapParams.swapAmount * 100 / depositETH;
        assertGt(swapRatio, 30, "Swap should be > 30% of deposit");
        assertLt(swapRatio, 70, "Swap should be < 70% of deposit");
    }
}
