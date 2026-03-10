// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import "../src/MultiPositionManager/periphery/SimpleLens.sol";

contract TestCarpetedPreviewVsActual is TestMultiPositionManager {
    // Note: Unified strategies now automatically handle carpet when needed
    // Using parent's strategies which already support carpet

    GaussianStrategy gaussianStrategy;
    UniformStrategy uniformStrategy;

    function setUp() public override {
        super.setUp();

        // Deploy the strategies we need for testing
        gaussianStrategy = new GaussianStrategy();
        uniformStrategy = new UniformStrategy();

        // Strategies are ready to use without registry
    }

    function test_PreviewVsActual_CarpetedGaussian() public {
        console.log("\n=== Testing Preview vs Actual for CarpetedGaussianStrategy ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit - Shares:", shares);
        vm.stopPrank();

        // Parameters for rebalance
        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;

        // Get preview with carpet positions
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: centerTick,
                ticksLeft: ticksLeft,
                ticksRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("PREVIEW RESULTS:");
        console.log("Number of ranges:", preview.ranges.length);
        console.log("Expected total token0:", preview.expectedTotal0);
        console.log("Expected total token1:", preview.expectedTotal1);

        // Log preview ranges
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            console.log("Preview Range", i);
            console.logInt(preview.ranges[i].lowerTick);
            console.logInt(preview.ranges[i].upperTick);
            if (i < preview.liquidities.length) {
                console.log("  Liquidity:", preview.liquidities[i]);
            }
        }

        // Check for full-range floor position in preview
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool previewHasFloor = false;
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            if (preview.ranges[i].lowerTick == minUsable && preview.ranges[i].upperTick == maxUsable) {
                previewHasFloor = true;
                break;
            }
        }

        console.log("\nPreview has full-range floor:", previewHasFloor);

        // Execute actual rebalance
        (uint256[2][] memory outMinGauss, uint256[2][] memory inMinGauss) = SimpleLensInMin
            .getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(gaussianStrategy),
            centerTick,
            ticksLeft,
            ticksRight,
            0,
            0.5e18,
            0.5e18,
            true,
            false,
            500, 500
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(gaussianStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 0, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMinGauss,
            inMinGauss
        );

        // Get actual positions after rebalance
        (IMultiPositionManager.Range[] memory actualPositions, IMultiPositionManager.PositionData[] memory actualData) =
            multiPositionManager.getPositions();

        console.log("\nACTUAL RESULTS:");
        console.log("Number of positions:", actualPositions.length);

        // Log actual positions
        for (uint256 i = 0; i < actualPositions.length; i++) {
            console.log("Actual Position", i);
            console.logInt(actualPositions[i].lowerTick);
            console.logInt(actualPositions[i].upperTick);
            console.log("  Liquidity:", actualData[i].liquidity);
        }

        // Check for full-range floor position in actual
        bool actualHasFloor = false;
        for (uint256 i = 0; i < actualPositions.length; i++) {
            if (actualPositions[i].lowerTick == minUsable && actualPositions[i].upperTick == maxUsable) {
                actualHasFloor = true;
                break;
            }
        }

        console.log("\nActual has full-range floor:", actualHasFloor);

        // Compare preview vs actual
        console.log("\n=== COMPARISON ===");

        // Number of positions should match
        assertEq(preview.ranges.length, actualPositions.length, "Number of positions should match");

        // Full-range floor should match
        assertEq(previewHasFloor, actualHasFloor, "Full-range floor should match");

        // Compare each position
        for (uint256 i = 0; i < actualPositions.length; i++) {
            assertEq(
                preview.ranges[i].lowerTick,
                actualPositions[i].lowerTick,
                string.concat("Lower tick should match for position ", vm.toString(i))
            );
            assertEq(
                preview.ranges[i].upperTick,
                actualPositions[i].upperTick,
                string.concat("Upper tick should match for position ", vm.toString(i))
            );
        }

        console.log("[PASS] All positions match between preview and actual!");
    }

    function test_PreviewVsActual_CarpetedUniform() public {
        console.log("\n=== Testing Preview vs Actual for CarpetedUniformStrategy ===\n");

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

        // Parameters
        int24 centerTick = 0;
        uint24 ticksLeft = 1500;
        uint24 ticksRight = 1500;

        // Get preview with carpet positions
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(uniformStrategy),
                centerTick: centerTick,
                ticksLeft: ticksLeft,
                ticksRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("Preview ranges:", preview.ranges.length);

        // Execute actual rebalance
        (uint256[2][] memory outMinUnif, uint256[2][] memory inMinUnif) = SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(uniformStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMinUnif,
            inMinUnif
        );

        // Get actual positions
        (IMultiPositionManager.Range[] memory actualPositions,) = multiPositionManager.getPositions();

        console.log("Actual positions:", actualPositions.length);

        // Compare
        assertEq(preview.ranges.length, actualPositions.length, "Number of positions should match for uniform strategy");

        // Check tick ranges match
        for (uint256 i = 0; i < actualPositions.length; i++) {
            assertEq(preview.ranges[i].lowerTick, actualPositions[i].lowerTick, "Lower ticks should match");
            assertEq(preview.ranges[i].upperTick, actualPositions[i].upperTick, "Upper ticks should match");
        }

        console.log("[PASS] Uniform strategy preview matches actual!");
    }

    function test_PreviewVsActual_CarpetedExponential() public {
        console.log("\n=== Testing Preview vs Actual for CarpetedExponentialStrategy ===\n");

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

        // Parameters
        int24 centerTick = 0;
        uint24 ticksLeft = 1200;
        uint24 ticksRight = 1200;

        // Get preview with carpet positions
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(exponentialStrategy),
                centerTick: centerTick,
                ticksLeft: ticksLeft,
                ticksRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("Preview ranges:", preview.ranges.length);

        // Execute actual rebalance
        (uint256[2][] memory outMinExp, uint256[2][] memory inMinExp) = SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMinExp,
            inMinExp
        );

        // Get actual positions
        (IMultiPositionManager.Range[] memory actualPositions, IMultiPositionManager.PositionData[] memory actualData) =
            multiPositionManager.getPositions();

        console.log("Actual positions:", actualPositions.length);

        // Compare count
        assertEq(
            preview.ranges.length, actualPositions.length, "Number of positions should match for exponential strategy"
        );

        // Check ranges match
        for (uint256 i = 0; i < actualPositions.length; i++) {
            assertEq(preview.ranges[i].lowerTick, actualPositions[i].lowerTick, "Lower ticks should match");
            assertEq(preview.ranges[i].upperTick, actualPositions[i].upperTick, "Upper ticks should match");
        }

        // Verify exponential distribution (center should have more liquidity)
        if (actualPositions.length > 2) {
            uint256 centerIdx = actualPositions.length / 2;
            uint256 centerLiquidity = actualData[centerIdx].liquidity;
            int24 minUsable = TickMath.minUsableTick(60);
            int24 maxUsable = TickMath.maxUsableTick(60);
            uint256 edgeIdx = 0;
            for (uint256 i = 0; i < actualPositions.length; i++) {
                if (actualPositions[i].lowerTick == minUsable && actualPositions[i].upperTick == maxUsable) {
                    continue;
                }
                edgeIdx = i;
                break;
            }
            uint256 edgeLiquidity = actualData[edgeIdx].liquidity;

            console.log("Center liquidity:", centerLiquidity);
            console.log("Edge liquidity:", edgeLiquidity);

            // Center should have significantly more liquidity in exponential
            if (edgeIdx != centerIdx) {
                assertTrue(centerLiquidity > edgeLiquidity, "Exponential should have more liquidity at center");
            }
        }

        console.log("[PASS] Exponential strategy preview matches actual!");
    }

    function test_CarpetWeightVerification() public {
        console.log("\n=== Verifying Carpet Weight Allocation ===\n");

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

        // Rebalance with carpeted Gaussian
        (uint256[2][] memory outMinWeight, uint256[2][] memory inMinWeight) = SimpleLensInMin
            .getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1200, 1200, 0, 0.5e18, 0.5e18, true, false, 500, 500
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMinWeight,
            inMinWeight
        );

        // Get actual positions
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        // Calculate total liquidity and floor liquidity
        uint256 totalLiquidity = 0;
        uint256 floorLiquidity = 0;
        bool hasFloor = false;

        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        for (uint256 i = 0; i < positions.length; i++) {
            totalLiquidity += positionData[i].liquidity;

            // Check if this is the full-range floor position
            if (positions[i].lowerTick == minUsable && positions[i].upperTick == maxUsable) {
                floorLiquidity = positionData[i].liquidity;
                hasFloor = true;
                console.log("Found full-range floor position", i);
                console.log("  Liquidity:", positionData[i].liquidity);
            }
        }

        console.log("\nTotal liquidity:", totalLiquidity);
        console.log("Floor liquidity:", floorLiquidity);

        assertTrue(hasFloor, "Full-range floor should be present");
        assertGt(floorLiquidity, 0, "Full-range floor should mint liquidity");

        console.log("[PASS] Full-range floor liquidity verified!");
    }
}
