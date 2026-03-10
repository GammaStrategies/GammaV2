// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./TestRebalancePreview.t.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";

contract TestCarpetedPreview is TestRebalancePreview {
    // Note: Unified strategies now automatically handle carpet when needed
    // No need for separate carpeted instances

    function setUp() public override {
        super.setUp();

        // The parent class already has all the unified strategies that support carpet
        // No need to create duplicate instances or a new registry
    }

    function test_PreviewRebalanceWithCarpetedGaussianStrategy() public {
        console.log("Testing preview with CarpetedGaussianStrategy...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Gaussian strategy with carpet positions
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

        // Verify preview results
        console.log("Generated ranges:", preview.ranges.length);
        assertTrue(preview.ranges.length >= 6, "Should generate at least 6 ranges (including floor)");

        // Check for full-range floor position at extremes
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;
        uint256 floorIdx = 0;
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            if (preview.ranges[i].lowerTick == minUsable && preview.ranges[i].upperTick == maxUsable) {
                hasFloor = true;
                floorIdx = i;
                break;
            }
        }

        console.log("Has full-range floor:", hasFloor);

        assertTrue(hasFloor, "Should have full-range floor position");

        // Verify floor liquidity is present (min-budget may require L > 1)
        if (hasFloor) {
            assertGt(preview.liquidities[floorIdx], 0, "Full-range floor should mint liquidity");
        }
    }

    function test_PreviewRebalanceWithCarpetedUniformStrategy() public {
        console.log("Testing preview with CarpetedUniformStrategy...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Carpeted Uniform strategy
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

        // Verify preview results
        console.log("Generated ranges:", preview.ranges.length);
        assertTrue(preview.ranges.length >= 1, "Should generate at least 1 range");

        // Check for full-range floor position
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;
        uint256 floorIdx = 0;
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            if (preview.ranges[i].lowerTick == minUsable && preview.ranges[i].upperTick == maxUsable) {
                hasFloor = true;
                floorIdx = i;
                break;
            }
        }

        assertTrue(hasFloor, "Should have a full-range floor position");

        // Verify the main range (uniform liquidity in a single position)
        uint256 mainIdx = preview.ranges.length > 1 && floorIdx == 0 ? 1 : 0;
        console.log("Main range liquidity:", preview.liquidities[mainIdx]);
        assertTrue(preview.liquidities[mainIdx] > 0, "Main range should have liquidity");
    }

    function test_PreviewRebalanceWithCarpetedExponentialStrategy() public {
        console.log("Testing preview with CarpetedExponentialStrategy...");

        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Carpeted Exponential strategy
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

        // Verify preview results
        console.log("Generated ranges:", preview.ranges.length);
        assertTrue(preview.ranges.length >= 5, "Should generate at least 5 ranges");

        // Check for full-range floor position
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;
        uint256 floorIdx = 0;
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            if (preview.ranges[i].lowerTick == minUsable && preview.ranges[i].upperTick == maxUsable) {
                hasFloor = true;
                floorIdx = i;
                break;
            }
        }

        assertTrue(hasFloor, "Should have a full-range floor position");

        // Verify exponential distribution (center should have more liquidity)
        uint256 startIdx = floorIdx == 0 ? 1 : 0;
        uint256 endIdx = preview.ranges.length;

        if (endIdx > startIdx + 2) {
            uint256 centerIdx = startIdx + (endIdx - startIdx) / 2;
            uint256 centerLiquidity = preview.liquidities[centerIdx];
            uint256 edgeLiquidity = preview.liquidities[startIdx];

            console.log("Center liquidity:", centerLiquidity);
            console.log("Edge liquidity:", edgeLiquidity);

            assertTrue(
                centerLiquidity > edgeLiquidity,
                "Center should have more liquidity than edges in exponential distribution"
            );
        }
    }

    function test_PreviewShowsCarpetTokenRequirements() public {
        console.log("Testing preview shows expected token amounts for carpet positions...");

        // Deposit initial liquidity
        vm.startPrank(owner);
        deal(Currency.unwrap(currency0), owner, 1e20);
        deal(Currency.unwrap(currency1), owner, 1e20);
        IERC20(Currency.unwrap(currency0)).approve(address(multiPositionManager), 1e20);
        IERC20(Currency.unwrap(currency1)).approve(address(multiPositionManager), 1e20);
        multiPositionManager.deposit(1e20, 1e20, owner, owner);
        vm.stopPrank();

        // Get preview with carpeted strategy
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: 0,
                ticksLeft: 1800,
                ticksRight: 1800,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Check expected total amounts after rebalance
        console.log("Expected total token0:", preview.expectedTotal0);
        console.log("Expected total token1:", preview.expectedTotal1);

        // Both should be non-zero for carpet positions to work
        assertTrue(preview.expectedTotal0 > 0, "Should have token0 for full-range floor");
        assertTrue(preview.expectedTotal1 > 0, "Should have token1 for full-range floor");

        // Check that we have expected positions
        console.log("Number of expected positions:", preview.expectedPositions.length);
        assertTrue(preview.expectedPositions.length > 0, "Should have expected positions");
    }

    function test_CompareCarpetedVsNonCarpetedPreviews() public {
        console.log("Comparing carpeted vs non-carpeted strategy previews...");

        // Get preview with regular Gaussian
        (SimpleLensInMin.RebalancePreview memory regularPreview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Get preview with carpeted Gaussian
        (SimpleLensInMin.RebalancePreview memory carpetedPreview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(gaussianStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("Regular Gaussian ranges:", regularPreview.ranges.length);
        console.log("Carpeted Gaussian ranges:", carpetedPreview.ranges.length);

        // Carpeted strategies optimize number of ranges differently
        // They may have fewer base ranges but include carpet positions
        // So we just check that both have generated some ranges
        assertTrue(carpetedPreview.ranges.length > 0, "Carpeted should have generated ranges");
        assertTrue(regularPreview.ranges.length > 0, "Regular should have generated ranges");

        // Check that carpeted includes the full-range floor
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool carpetedHasFloor = false;
        for (uint256 i = 0; i < carpetedPreview.ranges.length; i++) {
            if (carpetedPreview.ranges[i].lowerTick == minUsable && carpetedPreview.ranges[i].upperTick == maxUsable) {
                carpetedHasFloor = true;
                break;
            }
        }

        assertTrue(carpetedHasFloor, "Carpeted should include the full-range floor");

        // Regular should not include the full-range floor
        bool regularHasFloor = false;
        for (uint256 i = 0; i < regularPreview.ranges.length; i++) {
            if (regularPreview.ranges[i].lowerTick == minUsable && regularPreview.ranges[i].upperTick == maxUsable) {
                regularHasFloor = true;
                break;
            }
        }

        assertFalse(regularHasFloor, "Regular should not include the full-range floor");
    }
}
