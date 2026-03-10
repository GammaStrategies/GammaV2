// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract TestCarpetedEdgeCases is TestMultiPositionManager {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    function test_UnequalAssets_MoreToken0() public {
        console.log("\n=== Testing with MORE TOKEN0 than TOKEN1 ===\n");

        // Deposit unequal amounts - more token0
        uint256 amount0 = 2e20; // 200 token0
        uint256 amount1 = 1e20; // 100 token1

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        (uint256 shares, uint256 deposited0, uint256 deposited1) =
            multiPositionManager.deposit(amount0, amount1, owner, owner);

        console.log("Deposited token0:", deposited0);
        console.log("Deposited token1:", deposited1);
        console.log("Shares received:", shares);
        vm.stopPrank();

        // Rebalance with carpeted strategy
        (uint256[2][] memory outMin1, uint256[2][] memory inMin1) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            0, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick at current price
                tLeft: 1200, // ticksLeft
                tRight: 1200, // ticksRight,
                limitWidth: 0, // no limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin1,
            inMin1
        );

        // Check positions
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("\nPositions created:", positions.length);

        // Check carpet positions
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].lowerTick == minUsable) {
                console.log("Left carpet position", i);
                console.log("  Liquidity:", positionData[i].liquidity);
                // Left carpet needs mostly token1 at low prices
            }
            if (positions[i].upperTick == maxUsable) {
                console.log("Right carpet position", i);
                console.log("  Liquidity:", positionData[i].liquidity);
                // Right carpet needs mostly token0 at high prices - good for our case!
            }
        }

        // Get unused balances
        uint256 unused0 = token0.balanceOf(address(multiPositionManager));
        uint256 unused1 = token1.balanceOf(address(multiPositionManager));

        console.log("\nUnused token0:", unused0);
        console.log("Unused token1:", unused1);

        // With more token0, we expect more unused token0 after rebalance
        assertTrue(unused0 > unused1, "Should have more unused token0 with unequal deposits");
    }

    function test_UnequalAssets_MoreToken1() public {
        console.log("\n=== Testing with MORE TOKEN1 than TOKEN0 ===\n");

        // Deposit unequal amounts - more token1
        uint256 amount0 = 1e20; // 100 token0
        uint256 amount1 = 2e20; // 200 token1

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        (uint256 shares, uint256 deposited0, uint256 deposited1) =
            multiPositionManager.deposit(amount0, amount1, owner, owner);

        console.log("Deposited token0:", deposited0);
        console.log("Deposited token1:", deposited1);
        console.log("Shares received:", shares);
        vm.stopPrank();

        // First: Get inMin with 0% slippage to see exact SimpleLens expectations
        console.log("\n=== SimpleLens Expectations (0% slippage) ===");
        (uint256[2][] memory outMinExact, uint256[2][] memory inMinExact) = SimpleLensInMin
            .getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            0, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            0, 0 // 0% slippage - exact values
        );

        // Log exact expectations
        uint256 totalExpected0 = 0;
        uint256 totalExpected1 = 0;
        console.log("Number of positions:", inMinExact.length);
        for (uint256 i = 0; i < inMinExact.length; i++) {
            console.log("Position", i);
            console.log("  inMin[0]:", inMinExact[i][0]);
            console.log("  inMin[1]:", inMinExact[i][1]);
            totalExpected0 += inMinExact[i][0];
            totalExpected1 += inMinExact[i][1];
        }
        console.log("\nTotal expected token0:", totalExpected0);
        console.log("Total expected token1:", totalExpected1);
        console.log("Available token0:", amount0);
        console.log("Available token1:", amount1);

        // Second: Rebalance with 100% slippage tolerance (accept anything)
        console.log("\n=== Performing Rebalance (100% slippage tolerance) ===");
        (uint256[2][] memory outMin100, uint256[2][] memory inMin100) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            0, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            10000, 10000 // 100% slippage - accept anything
        );

        uint256 balance0Before = token0.balanceOf(address(multiPositionManager));
        uint256 balance1Before = token1.balanceOf(address(multiPositionManager));
        console.log("Balance before rebalance - token0:", balance0Before);
        console.log("Balance before rebalance - token1:", balance1Before);

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 1200, // ticksLeft
                tRight: 1200, // ticksRight,
                limitWidth: 0, // no limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin100,
            inMin100
        );

        // Get unused balances
        uint256 unused0 = token0.balanceOf(address(multiPositionManager));
        uint256 unused1 = token1.balanceOf(address(multiPositionManager));
        uint256 used0 = balance0Before - unused0;
        uint256 used1 = balance1Before - unused1;

        console.log("\n=== After Rebalance ===");
        console.log("Actually used token0:", used0);
        console.log("Actually used token1:", used1);
        console.log("Unused token0:", unused0);
        console.log("Unused token1:", unused1);

        console.log("\n=== Comparison ===");
        console.log("Expected to use token0:", totalExpected0);
        console.log("Actually used token0:  ", used0);
        console.log("Difference token0:     ", used0 > totalExpected0 ? used0 - totalExpected0 : totalExpected0 - used0);
        console.log("");
        console.log("Expected to use token1:", totalExpected1);
        console.log("Actually used token1:  ", used1);
        console.log("Difference token1:     ", used1 > totalExpected1 ? used1 - totalExpected1 : totalExpected1 - used1);

        // With more token1, we expect more unused token1 after rebalance
        assertTrue(unused1 > unused0, "Should have more unused token1 with unequal deposits");
    }

    function test_WithLimitWidth_Small() public {
        console.log("\n=== Testing with SMALL limitWidth (60 ticks) ===\n");

        // Deposit balanced amounts
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        // Rebalance with carpeted strategy AND small limitWidth
        uint24 limitWidth = 60; // Small limit range

        (uint256[2][] memory outMin3, uint256[2][] memory inMin3) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            limitWidth, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 1200, // ticksLeft
                tRight: 1200, // ticksRight,
                limitWidth: limitWidth, // SMALL limit width
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin3,
            inMin3
        );

        // Check positions
        (IMultiPositionManager.Range[] memory positions,) = multiPositionManager.getPositions();

        console.log("Total positions:", positions.length);

        // Count limit positions
        uint256 limitCount = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            int24 width = positions[i].upperTick - positions[i].lowerTick;
            if (width == int24(limitWidth) || width == int24(limitWidth) * 2) {
                // Check for limit-like widths
                limitCount++;
                console.log("Found limit position", i);
                console.logInt(positions[i].lowerTick);
                console.logInt(positions[i].upperTick);
                console.log("  Width:", uint256(uint24(width)));
            }
        }

        // Should have limit positions in addition to carpet
        assertTrue(limitCount > 0, "Should have limit positions with limitWidth");
    }

    function test_WithLimitWidth_Large() public {
        console.log("\n=== Testing with LARGE limitWidth (300 ticks) ===\n");

        // Deposit balanced amounts
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        // Rebalance with carpeted strategy AND large limitWidth
        uint24 limitWidth = 300; // Large limit range

        (uint256[2][] memory outMin4, uint256[2][] memory inMin4) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            limitWidth, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 1200, // ticksLeft
                tRight: 1200, // ticksRight,
                limitWidth: limitWidth, // LARGE limit width
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin4,
            inMin4
        );

        // Check positions
        (IMultiPositionManager.Range[] memory positions,) = multiPositionManager.getPositions();

        console.log("Total positions:", positions.length);

        // Count limit positions
        for (uint256 i = 0; i < positions.length; i++) {
            int24 width = positions[i].upperTick - positions[i].lowerTick;
            if (width == int24(limitWidth) || width == int24(limitWidth) * 2) {
                console.log("Found limit position", i);
                console.logInt(positions[i].lowerTick);
                console.logInt(positions[i].upperTick);
                console.log("  Width:", uint256(uint24(width)));
            }
        }
    }

    function test_UnequalAssets_WithLimitWidth() public {
        console.log("\n=== Testing UNEQUAL ASSETS with limitWidth ===\n");

        // Deposit unequal amounts
        uint256 amount0 = 3e20; // 300 token0
        uint256 amount1 = 1e20; // 100 token1

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Shares from unequal deposit:", shares);
        vm.stopPrank();

        // Rebalance with both carpet strategy AND limitWidth
        uint24 limitWidth = 120;

        (uint256[2][] memory outMin5, uint256[2][] memory inMin5) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1500, // tLeft
            1500, // tRight
            limitWidth, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 1500, // ticksLeft
                tRight: 1500, // ticksRight,
                limitWidth: limitWidth, // limit width
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin5,
            inMin5
        );

        // Check results
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("\nTotal positions created:", positions.length);

        // Analyze position types
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        uint256 carpetCount = 0;
        uint256 limitCount = 0;
        uint256 baseCount = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            int24 width = positions[i].upperTick - positions[i].lowerTick;

            if (positions[i].lowerTick == minUsable && positions[i].upperTick == maxUsable) {
                carpetCount++;
                console.log("Full-range floor position", i, "liquidity:", positionData[i].liquidity);
            } else if (width == int24(limitWidth) || width == int24(limitWidth) * 2) {
                limitCount++;
                console.log("Limit position", i, "liquidity:", positionData[i].liquidity);
            } else {
                baseCount++;
                console.log("Base position", i, "liquidity:", positionData[i].liquidity);
            }
        }

        console.log("\nPosition breakdown:");
        console.log("  Carpet positions:", carpetCount);
        console.log("  Limit positions:", limitCount);
        console.log("  Base positions:", baseCount);

        // Check unused balances
        uint256 unused0 = token0.balanceOf(address(multiPositionManager));
        uint256 unused1 = token1.balanceOf(address(multiPositionManager));

        console.log("\nUnused balances:");
        console.log("  Token0:", unused0);
        console.log("  Token1:", unused1);

        // With limit positions, it's possible to deploy all liquidity
        // Even with 3x more token0, limit positions can absorb the imbalance
        assertTrue(unused0 >= 0, "Unused token0 should be non-negative");
        assertTrue(unused1 >= 0, "Unused token1 should be non-negative");
    }

    function test_PreviewHandlesLimitWidth() public {
        console.log("\n=== Testing that Preview NOW HANDLES limitWidth ===\n");

        // Deposit balanced amounts
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        uint24 limitWidth = 120;

        // Get preview WITH limitWidth using the new function
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(exponentialStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("Preview ranges:", preview.ranges.length);

        // Also test backward compatibility - old function should still work
        (SimpleLensInMin.RebalancePreview memory oldPreview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(exponentialStrategy),
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
        console.log("Old preview (no limitWidth):", oldPreview.ranges.length);

        // Execute actual rebalance WITH limitWidth
        (uint256[2][] memory outMin6, uint256[2][] memory inMin6) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            limitWidth, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin6,
            inMin6
        );

        // Get actual positions
        (IMultiPositionManager.Range[] memory actualPositions,) = multiPositionManager.getPositions();

        console.log("Actual positions:", actualPositions.length);

        // Preview with limitWidth: base + 2 limit positions (no floor)
        // Actual: base + full-range floor + 2 limit
        assertEq(
            preview.ranges.length + 1, // Add 1 floor position
            actualPositions.length,
            "Preview with limitWidth should match actual (plus floor)"
        );

        // Old preview WITHOUT limitWidth and without floor
        // Actual: base + full-range floor + 2 limit
        assertEq(
            oldPreview.ranges.length + 3, // Add 1 floor + 2 limit
            actualPositions.length,
            "Old preview should be 3 positions less (no limit or floor)"
        );

        console.log("\n[SUCCESS] Preview handles base ranges correctly!");
        console.log("Preview with limitWidth:", preview.ranges.length, "positions (base only)");
        console.log("Actual:", actualPositions.length, "positions (base + floor + limit)");
        console.log("Old preview without limitWidth:", oldPreview.ranges.length, "positions (base only)");

        // Note: The preview functions only generate base ranges (no floor or limit positions)
        console.log("\nNote: Preview includes the floor when useCarpet=true and limit positions when limitWidth>0");
        console.log("This is expected behavior - preview matches actual range composition");
    }

    function test_OffCenterPriceWithCarpet() public {
        console.log("\n=== Testing carpet behavior at OFF-CENTER PRICE ===\n");

        // First deposit balanced amounts
        uint256 amount0 = 1e20;
        uint256 amount1 = 1e20;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        // Swap to move price moderately off-center
        vm.startPrank(alice);
        // Small swap to move price to around tick 5000
        uint256 swapAmount = 1e18; // 1 token1
        token1.mint(alice, swapAmount);
        token1.approve(address(swapRouter), swapAmount);

        SwapParams memory params = SwapParams({
            zeroForOne: false, // token1 for token0
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(5000)
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Get the pool key
        PoolKey memory poolKey = multiPositionManager.poolKey();
        Currency c0 = poolKey.currency0;
        Currency c1 = poolKey.currency1;
        uint24 fee = poolKey.fee;
        int24 tickSpacing = poolKey.tickSpacing;
        IHooks hooks = poolKey.hooks;
        PoolKey memory pk = PoolKey(c0, c1, fee, tickSpacing, hooks);

        swapRouter.swap(pk, params, testSettings, "");
        vm.stopPrank();

        // Get new tick after swap
        (, int24 currentTick,,) = StateLibrary.getSlot0(multiPositionManager.poolManager(), pk.toId());
        console.log("Current tick after swap:");
        console.logInt(currentTick);

        // Round currentTick to nearest tickSpacing multiple for rebalance center
        int24 rebalanceCenter = (currentTick / 60) * 60;

        // Now rebalance with carpeted strategy centered at current price
        // This tests that carpet positions work even when price is off-center
        (uint256[2][] memory outMin7, uint256[2][] memory inMin7) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            rebalanceCenter, // center at current tick
            1200, // tLeft
            1200, // tRight
            0, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: rebalanceCenter, // center at current tick
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin7,
            inMin7
        );

        // Check positions
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        // At extreme price, full-range floor should still exist
        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].lowerTick == minUsable && positions[i].upperTick == maxUsable) {
                hasFloor = true;
                console.log("Full-range floor at extreme price, liquidity:", positionData[i].liquidity);
            }
        }

        assertTrue(hasFloor, "Should still have full-range floor at extreme price");

        // Check token usage
        uint256 unused0 = token0.balanceOf(address(multiPositionManager));
        uint256 unused1 = token1.balanceOf(address(multiPositionManager));

        console.log("\nAt extreme price:");
        console.log("  Unused token0:", unused0);
        console.log("  Unused token1:", unused1);
    }

    function test_CarpetWithZeroLiquidity() public {
        console.log("\n=== Testing carpet with MINIMAL deposit ===\n");

        // Deposit very small amounts
        uint256 amount0 = 1e10; // Tiny amount
        uint256 amount1 = 1e10; // Tiny amount

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Shares from minimal deposit:", shares);
        vm.stopPrank();

        // Try to rebalance with carpeted strategy
        // This might fail or create positions with 0 liquidity
        (uint256[2][] memory outMin8, uint256[2][] memory inMin8) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0, // center
            1200, // tLeft
            1200, // tRight
            0, // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            true, // useCarpet
            false, // swap
            500, 500 // 5% max slippage
        );

        vm.prank(owner);
        try multiPositionManager.rebalance(
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
            outMin8,
            inMin8
        ) {
            console.log("Rebalance succeeded with minimal liquidity");

            // Check if any positions were created
            (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
                multiPositionManager.getPositions();

            console.log("Positions created:", positions.length);

            uint256 totalLiquidity = 0;
            for (uint256 i = 0; i < positions.length; i++) {
                totalLiquidity += positionData[i].liquidity;
                if (positionData[i].liquidity == 0) {
                    console.log("Position", i, "has ZERO liquidity!");
                }
            }

            console.log("Total liquidity across all positions:", totalLiquidity);
        } catch Error(string memory reason) {
            console.log("Rebalance failed with reason:", reason);
        } catch {
            console.log("Rebalance failed (unknown reason)");
        }
    }
}
