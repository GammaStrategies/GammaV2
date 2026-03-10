// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import "../src/MultiPositionManager/periphery/SimpleLens.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract TestLiquidityVisualization is TestMultiPositionManager {
    SimpleLens visualizationLens;

    function setUp() public override {
        super.setUp();
        visualizationLens = new SimpleLens(manager);
    }

    function test_Visualization_50_50_Ratio() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 50/50 Ratio with Exponential Strategy ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with exponential strategy
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Get positions and visualize
        _visualizePositions("50/50 Ratio at Current Tick");

        vm.stopPrank();
    }

    function test_Visualization_80_20_Ratio() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 80/20 Ratio with Exponential Strategy ===\n");

        // Setup initial deposit (80/20 ratio)
        uint256 amount0 = 160e18;
        uint256 amount1 = 40e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with exponential strategy
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        // Get positions and visualize
        _visualizePositions("80/20 Ratio at Current Tick");

        vm.stopPrank();
    }

    function test_Visualization_50_50_Ratio_Offset() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 50/50 Ratio with Center Tick Offset ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with center tick 2 tickSpacings to the left (120 ticks)
        int24 centerTick = -120; // 2 * 60 tick spacing
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin3, uint256[2][] memory inMin3) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin3,
            inMin3
        );

        // Get positions and visualize
        _visualizePositions("50/50 Ratio with Center at -120");

        vm.stopPrank();
    }

    function test_Visualization_80_20_Ratio_Offset() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 80/20 Ratio with Center Tick Offset ===\n");

        // Setup initial deposit (80/20 ratio)
        uint256 amount0 = 160e18;
        uint256 amount1 = 40e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with center tick 2 tickSpacings to the left (120 ticks)
        int24 centerTick = -120; // 2 * 60 tick spacing
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin4, uint256[2][] memory inMin4) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin4,
            inMin4
        );

        // Get positions and visualize
        _visualizePositions("80/20 Ratio with Center at -120");

        vm.stopPrank();
    }

    function test_Visualization_WithdrawSingleToken_Rebalance() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 80/20 to 50/50 via WithdrawSingleToken ===\n");

        // Setup initial deposit (80/20 ratio)
        uint256 amount0 = 160e18;
        uint256 amount1 = 40e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit complete. Shares:", shares);
        console.log("Initial token0:", amount0 / 1e18, "Initial token1:", amount1 / 1e18);

        // First rebalance with exponential strategy
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin5, uint256[2][] memory inMin5) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin5,
            inMin5
        );

        console.log("\n=== AFTER INITIAL REBALANCE (80/20 ratio) ===");
        _visualizePositions("Distribution with 80/20 Initial Ratio");

        // Calculate how much token0 to withdraw to achieve 50/50 ratio
        (uint256 total0Before, uint256 total1Before,,) = multiPositionManager.getTotalAmounts();
        console.log("\nTotal amounts before withdrawal:");
        console.log("  Token0:", total0Before / 1e18, "Token1:", total1Before / 1e18);

        // To get to 50/50 ratio with our 40 token1, we need 40 token0
        // So we need to withdraw: 160 - 40 = 120 token0
        uint256 token0ToWithdraw = 120e18;

        // Calculate amount to withdraw (in terms of token amount, not shares)
        uint256 amountToWithdraw = token0ToWithdraw;

        console.log("\nWithdrawing single token to rebalance to 50/50:");
        console.log("  Target: 40 token0 to match 40 token1");
        console.log("  Token0 to withdraw:", token0ToWithdraw / 1e18);
        console.log("  Amount to withdraw:", amountToWithdraw / 1e18);

        // Perform a custom withdrawal (token0 only)
        SimpleLens lens = new SimpleLens(manager);

        // Use previewWithdrawCustom to get proper outMin
        IMultiPositionManager.RebalanceParams memory emptyParams;
        (,, uint256[2][] memory outMinWithdraw,,,) = lens.previewWithdrawCustom(
            multiPositionManager,
            amountToWithdraw, // amount0Desired
            0, // amount1Desired
            50, // 0.5% max slippage
            false,
            emptyParams
        );

        (uint256 amount0Out, uint256 amount1Out, uint256 sharesBurned) = multiPositionManager.withdrawCustom(
            amountToWithdraw, // amount0Desired
            0, // amount1Desired
            outMinWithdraw
        );

        console.log("  Actual amount withdrawn:", amount0Out / 1e18);
        console.log("  Shares burned:", sharesBurned);

        // Check new ratio
        (uint256 total0After, uint256 total1After,,) = multiPositionManager.getTotalAmounts();
        console.log("\nTotal amounts after withdrawal:");
        console.log("  Token0:", total0After / 1e18, "Token1:", total1After / 1e18);
        uint256 ratioAfter = (total0After * 100) / (total0After + total1After);
        console.log("  Token0 percentage:", ratioAfter, "%");

        console.log("\n=== AFTER WITHDRAWSINGLETOKEN (targeting 50/50) ===");
        _visualizePositions("Distribution after WithdrawSingleToken");

        vm.stopPrank();
    }

    function test_Visualization_Rebalance_After_Swap() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: Rebalance After Price Movement ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit complete. Shares:", shares);
        console.log("Initial token0:", amount0 / 1e18, "Initial token1:", amount1 / 1e18);

        // First rebalance with exponential strategy at tick 0
        (uint256[2][] memory outMin6, uint256[2][] memory inMin6) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: 0, // centerTick
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin6,
            inMin6
        );

        console.log("\n=== AFTER INITIAL REBALANCE (50/50 at tick 0) ===");
        _visualizePositions("Initial Distribution - Center at Tick 0");

        // Check current tick before swap
        int24 tickBefore = multiPositionManager.currentTick();
        console.log("\nCurrent tick before swap:", tickBefore);

        // Perform a swap to move price (tick) to approximately 125
        // To move tick from 0 to 125, we need to buy token0 with token1
        // Price ratio at tick 125: 1.0001^125 ≈ 1.0125
        // We need to swap enough token1 to move the tick

        vm.stopPrank();
        vm.startPrank(alice);

        // Mint tokens to alice for swapping
        uint256 swapAmount = 50e18; // Swap 50 token1 for token0
        token1.mint(alice, swapAmount);
        token1.approve(address(swapRouter), swapAmount);

        console.log("\nPerforming swap: Selling", swapAmount / 1e18, "token1 for token0");

        // Perform the swap (selling token1 for token0 moves tick up)
        SwapParams memory params = SwapParams({
            zeroForOne: false, // Selling token1 for token0
            amountSpecified: -int256(swapAmount), // Negative for exact input
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(200) // Target around tick 200 as upper limit
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        vm.stopPrank();
        vm.startPrank(owner);

        // Get the current tick after swap
        int24 tickAfter = multiPositionManager.currentTick();
        console.log("Current tick after swap:", tickAfter);

        // Get total amounts after swap
        (uint256 total0AfterSwap, uint256 total1AfterSwap,,) = multiPositionManager.getTotalAmounts();
        console.log("Total amounts after swap:");
        console.log("  Token0:", total0AfterSwap / 1e18, "Token1:", total1AfterSwap / 1e18);

        console.log("\n=== AFTER SWAP (tick moved) ===");
        _visualizePositions("Distribution After Swap - Before Rebalance");

        // Second rebalance with center at the current tick
        // Get current tick and round to nearest tick spacing
        int24 centerTick = multiPositionManager.currentTick();
        centerTick = (centerTick / 60) * 60;

        console.log("\nRebalancing with center at current tick:", centerTick);

        (uint256[2][] memory outMin7, uint256[2][] memory inMin7) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: centerTick, // Center at current tick (rounded)
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin7,
            inMin7
        );

        console.log("\n=== AFTER SECOND REBALANCE (center at current tick) ===");
        _visualizePositions(string(abi.encodePacked("Final Distribution - Center at Tick ", _intToString(centerTick))));

        // Final totals
        (uint256 total0Final, uint256 total1Final,,) = multiPositionManager.getTotalAmounts();
        console.log("\nFinal total amounts:");
        console.log("  Token0:", total0Final / 1e18, "Token1:", total1Final / 1e18);

        vm.stopPrank();
    }

    function test_Visualization_Carpeted_50_50() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 50/50 with Carpeted Exponential Strategy ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit complete. Shares:", shares);
        console.log("Initial token0:", amount0 / 1e18, "Initial token1:", amount1 / 1e18);

        // Rebalance with carpeted exponential strategy
        (uint256[2][] memory outMin8, uint256[2][] memory inMin8) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: 0, // centerTick
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin8,
            inMin8
        );

        console.log("\n=== CARPETED EXPONENTIAL DISTRIBUTION ===");
        _visualizePositions("50/50 with Carpet Positions");

        vm.stopPrank();
    }

    function test_Visualization_Carpeted_80_20() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 80/20 with Carpeted Exponential Strategy ===\n");

        // Setup initial deposit (80/20 ratio)
        uint256 amount0 = 160e18;
        uint256 amount1 = 40e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit complete. Shares:", shares);
        console.log("Initial token0:", amount0 / 1e18, "Initial token1:", amount1 / 1e18);

        // Rebalance with carpeted exponential strategy
        (uint256[2][] memory outMin9, uint256[2][] memory inMin9) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: 0, // centerTick
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin9,
            inMin9
        );

        console.log("\n=== CARPETED EXPONENTIAL DISTRIBUTION ===");
        _visualizePositions("80/20 with Carpet Positions");

        vm.stopPrank();
    }

    function test_Visualization_Carpeted_After_Swap() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: Carpeted Strategy After Price Movement ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, owner, owner);
        console.log("Initial deposit complete. Shares:", shares);

        // First rebalance with carpeted strategy at tick 0
        (uint256[2][] memory outMin10, uint256[2][] memory inMin10) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: 0, // centerTick
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin10,
            inMin10
        );

        console.log("\n=== INITIAL CARPETED DISTRIBUTION ===");
        _visualizePositions("Initial Carpeted Distribution at Tick 0");

        // Check min/max ticks to see carpet positions
        int24 minUsableTick = TickMath.minUsableTick(60);
        int24 maxUsableTick = TickMath.maxUsableTick(60);
        console.log("\nCarpet position bounds:");
        console.log("  Min usable tick:", minUsableTick);
        console.log("  Max usable tick:", maxUsableTick);

        // Perform a swap
        vm.stopPrank();
        vm.startPrank(alice);

        uint256 swapAmount = 50e18;
        token1.mint(alice, swapAmount);
        token1.approve(address(swapRouter), swapAmount);

        console.log("\nPerforming swap: Selling", swapAmount / 1e18, "token1 for token0");

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(200)
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        vm.stopPrank();
        vm.startPrank(owner);

        int24 tickAfter = multiPositionManager.currentTick();
        console.log("Current tick after swap:", tickAfter);

        console.log("\n=== AFTER SWAP (with carpet positions) ===");
        _visualizePositions("Carpeted Distribution After Swap");

        // Second rebalance with carpeted strategy at new tick
        int24 centerTick = (tickAfter / 60) * 60;

        console.log("\nRebalancing carpeted strategy with center at:", centerTick);

        (uint256[2][] memory outMin11, uint256[2][] memory inMin11) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                center: centerTick,
                tLeft: 1800, // ticksLeft
                tRight: 1800, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin11,
            inMin11
        );

        console.log("\n=== FINAL CARPETED DISTRIBUTION ===");
        _visualizePositions(
            string(abi.encodePacked("Final Carpeted Distribution - Center at ", _intToString(centerTick)))
        );

        vm.stopPrank();
    }

    function test_Visualization_50_50_Asymmetric_Range() public {
        console.log("\n=== LIQUIDITY DISTRIBUTION: 50/50 Ratio with Asymmetric Range (More Left) ===\n");

        // Setup initial deposit (50/50 ratio)
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with much more ticks to the left than right
        int24 centerTick = 0;
        uint24 ticksLeft = 3000; // Much wider range to the left
        uint24 ticksRight = 600; // Narrow range to the right
        uint24 limitWidth = 60; // 1 tick spacing

        (uint256[2][] memory outMin12, uint256[2][] memory inMin12) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: limitWidth,
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
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: limitWidth,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin12,
            inMin12
        );

        // Get positions and visualize
        _visualizePositions("50/50 Ratio - Asymmetric (3000 left, 600 right)");

        vm.stopPrank();
    }

    function _visualizePositions(string memory title) internal view override {
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        // Get current tick
        int24 currentTick = multiPositionManager.currentTick();

        // Separate base positions and limit position
        uint256 baseCount = multiPositionManager.basePositionsLength();

        console.log(title);
        console.log(
            "Current Tick:", currentTick < 0 ? "-" : "", currentTick < 0 ? uint24(-currentTick) : uint24(currentTick)
        );
        console.log("Base Positions:", baseCount);
        if (positions.length > baseCount) {
            console.log("Limit Position: YES");
        }
        console.log("");

        // Find max liquidity for scaling
        uint128 maxLiquidity = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }

        // Create the graph
        console.log("Liquidity Distribution Graph:");
        console.log("Legend: # = Token0, - = Token1");
        console.log("==============================");

        // Draw Y-axis scale
        console.log("100% |");
        console.log(" 80% |");
        console.log(" 60% |");
        console.log(" 40% |");
        console.log(" 20% |");
        console.log("  0% +", _repeatChar("=", 80));
        console.log("     Tick Ranges:");

        // Show positions with their tick ranges and liquidity bars
        for (uint256 i = 0; i < positions.length; i++) {
            if (positionData[i].liquidity > 0) {
                uint256 percentage = (uint256(positionData[i].liquidity) * 100) / uint256(maxLiquidity);

                // Determine which token the position holds
                bool hasToken0 = positionData[i].amount0 > 0;
                bool hasToken1 = positionData[i].amount1 > 0;
                string memory barChar;
                if (hasToken0 && hasToken1) {
                    barChar = "="; // Both tokens
                } else if (hasToken0) {
                    barChar = "#"; // Token0 only
                } else {
                    barChar = "-"; // Token1 only
                }

                string memory bar = _createBarWithChar(percentage, barChar);

                string memory posType = i < baseCount ? "Base" : "Limit";

                console.log(
                    string(
                        abi.encodePacked(
                            "  ",
                            posType,
                            " [",
                            _tickToString(positions[i].lowerTick),
                            ",",
                            _tickToString(positions[i].upperTick),
                            "]: ",
                            bar,
                            " (",
                            _uintToString(percentage),
                            "%)"
                        )
                    )
                );

                // Show token amounts
                if (positionData[i].amount0 > 0 || positionData[i].amount1 > 0) {
                    console.log(
                        string(
                            abi.encodePacked(
                                "       Token0: ",
                                _formatAmount(positionData[i].amount0),
                                " | Token1: ",
                                _formatAmount(positionData[i].amount1)
                            )
                        )
                    );
                }
            }
        }

        console.log("");

        // Show totals
        uint256 totalToken0 = 0;
        uint256 totalToken1 = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            totalToken0 += positionData[i].amount0;
            totalToken1 += positionData[i].amount1;
        }

        console.log("Total Liquidity Distribution:");
        console.log("  Total Token0:", _formatAmount(totalToken0));
        console.log("  Total Token1:", _formatAmount(totalToken1));

        // Show limit position details if it exists
        if (positions.length > baseCount) {
            console.log("\nLimit Position Details:");
            uint256 limitIdx = baseCount;
            console.log(
                "  Range:",
                _tickToString(positions[limitIdx].lowerTick),
                "to",
                _tickToString(positions[limitIdx].upperTick)
            );
            console.log("  Width:", uint24(positions[limitIdx].upperTick - positions[limitIdx].lowerTick), "ticks");
            console.log("  Liquidity:", uint256(positionData[limitIdx].liquidity));
            uint256 limitPercentage = (uint256(positionData[limitIdx].liquidity) * 100) / uint256(maxLiquidity);
            console.log("  Percentage of max:", limitPercentage, "%");
        }

        console.log("\n", _repeatChar("=", 80), "\n");
    }

    function _createBar(uint256 percentage) internal pure returns (string memory) {
        uint256 barLength = (percentage * 40) / 100; // Scale to 40 chars max
        if (barLength == 0 && percentage > 0) barLength = 1; // At least show something

        bytes memory bar = new bytes(barLength);
        for (uint256 i = 0; i < barLength; i++) {
            bar[i] = "#"; // Use ASCII character instead
        }
        return string(bar);
    }

    function _createBarWithChar(uint256 percentage, string memory char)
        internal
        pure
        override
        returns (string memory)
    {
        uint256 barLength = (percentage * 40) / 100; // Scale to 40 chars max
        if (barLength == 0 && percentage > 0) barLength = 1; // At least show something

        bytes memory charBytes = bytes(char);
        bytes memory bar = new bytes(barLength);
        for (uint256 i = 0; i < barLength; i++) {
            bar[i] = charBytes[0];
        }
        return string(bar);
    }

    function _repeatChar(string memory char, uint256 count) internal pure override returns (string memory) {
        bytes memory result = new bytes(count);
        bytes memory charBytes = bytes(char);
        for (uint256 i = 0; i < count; i++) {
            result[i] = charBytes[0];
        }
        return string(result);
    }

    function _tickToString(int24 tick) internal pure override returns (string memory) {
        if (tick < 0) {
            return string(abi.encodePacked("-", _uintToString(uint24(-tick))));
        }
        return _uintToString(uint24(tick));
    }

    function _intToString(int24 value) internal pure override returns (string memory) {
        if (value < 0) {
            return string(abi.encodePacked("-", _uintToString(uint24(-value))));
        }
        return _uintToString(uint24(value));
    }

    function _uintToString(uint256 value) internal pure override returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _formatAmount(uint256 amount) internal pure override returns (string memory) {
        if (amount == 0) return "0";

        // Convert to ether units (divide by 1e18)
        uint256 etherAmount = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e16; // Get 2 decimal places

        return
            string(abi.encodePacked(_uintToString(etherAmount), ".", decimal < 10 ? "0" : "", _uintToString(decimal)));
    }

    // ============ Weighted Position Visualization Tests ============

    function test_Visualization_Weighted_70_30() public {
        console.log("\n=== WEIGHTED LIQUIDITY DISTRIBUTION: 70/30 with WeightedGaussianStrategy ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted strategy - 70% token0, 30% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.7e18, // 70% token0
            weight1: 0.3e18, // 30% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedGaussian");
        console.log("Weight Distribution: 70% Token0, 30% Token1");
        _visualizePositions("70/30 Weighted Distribution");

        vm.stopPrank();
    }

    function test_Visualization_Weighted_30_70() public {
        console.log("\n=== WEIGHTED LIQUIDITY DISTRIBUTION: 30/70 with WeightedGaussianStrategy ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted strategy - 30% token0, 70% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.3e18, // 30% token0
            weight1: 0.7e18, // 70% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedGaussian");
        console.log("Weight Distribution: 30% Token0, 70% Token1");
        _visualizePositions("30/70 Weighted Distribution");

        vm.stopPrank();
    }

    function test_Visualization_Weighted_90_10() public {
        console.log("\n=== WEIGHTED LIQUIDITY DISTRIBUTION: 90/10 with WeightedGaussianStrategy ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted strategy - 90% token0, 10% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.9e18, // 90% token0
            weight1: 0.1e18, // 10% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedGaussian");
        console.log("Weight Distribution: 90% Token0, 10% Token1");
        _visualizePositions("90/10 Weighted Distribution");

        vm.stopPrank();
    }

    function test_Visualization_Weighted_After_Swap() public {
        console.log("\n=== WEIGHTED DISTRIBUTION AFTER PRICE MOVEMENT ===\n");

        // Setup initial deposit
        uint256 amount0 = 200e18;
        uint256 amount1 = 200e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // First rebalance with 60/40 weights
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1200, // Reduced range
            tRight: 1200, // Reduced range
            limitWidth: 60,
            weight0: 0.6e18, // 60% token0
            weight1: 0.4e18, // 40% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("\n=== INITIAL WEIGHTED DISTRIBUTION ===");
        console.log("Weight Distribution: 60% Token0, 40% Token1");
        _visualizePositions("Initial 60/40 Weighted Distribution");

        // Perform a swap to move the price
        console.log("\n>>> Performing large swap to move price...");

        // Swap token0 for token1 to move tick upward
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -50e18, // Negative for exactInput
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        token0.mint(owner, 50e18);
        token0.approve(address(swapRouter), 50e18);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, swapParams, testSettings, "");

        int24 tickAfter = multiPositionManager.currentTick();
        console.log(
            "Tick after swap:", tickAfter < 0 ? "-" : "", tickAfter < 0 ? uint24(-tickAfter) : uint24(tickAfter)
        );

        console.log("\n=== AFTER SWAP (weighted distribution) ===");
        _visualizePositions("Weighted Distribution After Price Movement");

        {
            // Rebalance with adjusted weights at new tick
            int24 centerTick = (tickAfter / 60) * 60;

            console.log("\nRebalancing with adjusted weights at new center:", centerTick);

            IMultiPositionManager.RebalanceParams memory params2 = IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: centerTick,
                tLeft: 1200, // Reduced range
                tRight: 1200, // Reduced range
                limitWidth: 60,
                weight0: 0.4e18, // Adjust to 40% token0
                weight1: 0.6e18, // Adjust to 60% token1
                useCarpet: false
            });

            (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params2.strategy,
            centerTick: params2.center,
            ticksLeft: params2.tLeft,
            ticksRight: params2.tRight,
            limitWidth: params2.limitWidth,
            weight0: params2.weight0,
            weight1: params2.weight1,
            useCarpet: params2.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params2, outMin2, inMin2);
        }

        console.log("\n=== REBALANCED WEIGHTED DISTRIBUTION ===");
        console.log("New Weight Distribution: 40% Token0, 60% Token1");
        _visualizePositions("Rebalanced 40/60 Weighted Distribution");

        vm.stopPrank();
    }

    function test_Visualization_Weighted_With_Offset() public {
        console.log("\n=== WEIGHTED DISTRIBUTION WITH TICK OFFSET ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted strategy and tick offset
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.75e18, // 75% token0
            weight1: 0.25e18, // 25% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedGaussian");
        console.log("Weight Distribution: 75% Token0, 25% Token1");
        console.log("Aim Tick: 0 (current)");
        console.log("Tick Offset Tolerance: 600");
        _visualizePositions("75/25 Weighted Distribution with Offset");

        vm.stopPrank();
    }

    function test_Visualization_Weighted_Asymmetric() public {
        console.log("\n=== ASYMMETRIC WEIGHTED DISTRIBUTION ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with asymmetric range and weighted distribution
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 2400, // Wider left range
            tRight: 1200, // Narrower right range
            limitWidth: 60,
            weight0: 0.65e18, // 65% token0
            weight1: 0.35e18, // 35% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedGaussian");
        console.log("Weight Distribution: 65% Token0, 35% Token1");
        console.log("Asymmetric Range: 2400 ticks left, 1200 ticks right");
        _visualizePositions("Asymmetric 65/35 Weighted Distribution");

        vm.stopPrank();
    }

    // ============ Weighted Exponential Visualization Tests ============

    function test_Visualization_WeightedExp_70_30() public {
        console.log("\n=== WEIGHTED EXPONENTIAL DISTRIBUTION: 70/30 ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted exponential strategy - 70% token0, 30% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.7e18, // 70% token0
            weight1: 0.3e18, // 30% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedExponential");
        console.log("Weight Distribution: 70% Token0, 30% Token1");
        _visualizePositions("70/30 Weighted Exponential Distribution");

        vm.stopPrank();
    }

    function test_Visualization_WeightedExp_30_70() public {
        console.log("\n=== WEIGHTED EXPONENTIAL DISTRIBUTION: 30/70 ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted exponential strategy - 30% token0, 70% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.3e18, // 30% token0
            weight1: 0.7e18, // 70% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 1000,
            maxSlippageInMin: 1000,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedExponential");
        console.log("Weight Distribution: 30% Token0, 70% Token1");
        _visualizePositions("30/70 Weighted Exponential Distribution");

        vm.stopPrank();
    }

    function test_Visualization_WeightedExp_90_10() public {
        console.log("\n=== WEIGHTED EXPONENTIAL DISTRIBUTION: 90/10 ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with weighted exponential strategy - 90% token0, 10% token1
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.9e18, // 90% token0
            weight1: 0.1e18, // 10% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedExponential");
        console.log("Weight Distribution: 90% Token0, 10% Token1");
        _visualizePositions("90/10 Weighted Exponential Distribution");

        vm.stopPrank();
    }

    function test_Visualization_WeightedExp_Asymmetric() public {
        console.log("\n=== ASYMMETRIC WEIGHTED EXPONENTIAL DISTRIBUTION ===\n");

        // Setup initial deposit
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Initial deposit
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with asymmetric range and weighted exponential distribution
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 2400, // Wider left range
            tRight: 1200, // Narrower right range
            limitWidth: 60,
            weight0: 0.65e18, // 65% token0
            weight1: 0.35e18, // 35% token1
            useCarpet: false
        });

        {
            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            multiPositionManager.rebalance(params, outMin, inMin);
        }

        console.log("Strategy: WeightedExponential");
        console.log("Weight Distribution: 65% Token0, 35% Token1");
        console.log("Asymmetric Range: 2400 ticks left, 1200 ticks right");
        _visualizePositions("Asymmetric 65/35 Weighted Exponential Distribution");

        vm.stopPrank();
    }

    function test_Visualization_ProportionalWeights_70_30() public {
        console.log("\n=== PROPORTIONAL WEIGHTS: 70/30 Distribution ===\n");

        uint256 amount0 = 70e18;
        uint256 amount1 = 30e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin13, uint256[2][] memory inMin13) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                tLeft: 1800,
                tRight: 1800,
                limitWidth: 60,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin13,
            inMin13
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("Expected: 70% token0, 30% token1");
        console.log("Actual token0:", actualPercentage0, "%");
        console.log("Actual token1:", 100 - actualPercentage0, "%");

        assertApproxEqRel(actualPercentage0, 70, 0.02e18, "Should be ~70% token0");

        _visualizePositions("Proportional 70/30 Distribution");

        vm.stopPrank();
    }

    function test_Visualization_ProportionalWeights_30_70() public {
        console.log("\n=== PROPORTIONAL WEIGHTS: 30/70 Distribution ===\n");

        uint256 amount0 = 30e18;
        uint256 amount1 = 70e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin14, uint256[2][] memory inMin14) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                tLeft: 1800,
                tRight: 1800,
                limitWidth: 60,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin14,
            inMin14
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("Expected: 30% token0, 70% token1");
        console.log("Actual token0:", actualPercentage0, "%");
        console.log("Actual token1:", 100 - actualPercentage0, "%");

        assertApproxEqRel(actualPercentage0, 30, 0.04e18, "Should be ~30% token0");

        _visualizePositions("Proportional 30/70 Distribution");

        vm.stopPrank();
    }

    function test_Visualization_ProportionalWeights_80_20() public {
        console.log("\n=== PROPORTIONAL WEIGHTS: 80/20 Distribution ===\n");

        uint256 amount0 = 80e18;
        uint256 amount1 = 20e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin15, uint256[2][] memory inMin15) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                tLeft: 1800,
                tRight: 1800,
                limitWidth: 60,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin15,
            inMin15
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("Expected: 80% token0, 20% token1");
        console.log("Actual token0:", actualPercentage0, "%");
        console.log("Actual token1:", 100 - actualPercentage0, "%");

        assertApproxEqRel(actualPercentage0, 80, 0.02e18, "Should be ~80% token0");

        _visualizePositions("Proportional 80/20 Distribution");

        vm.stopPrank();
    }

    function test_Visualization_ProportionalWeights_AfterPriceChange() public {
        console.log("\n=== PROPORTIONAL WEIGHTS: After Price Movement ===\n");

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin16, uint256[2][] memory inMin16) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                tLeft: 1800,
                tRight: 1800,
                limitWidth: 60,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin16,
            inMin16
        );

        console.log("\n=== Initial 50/50 Allocation ===");
        (uint256 total0Before, uint256 total1Before,,) = multiPositionManager.getTotalAmounts();
        console.log("Token0:", total0Before / 1e18, "Token1:", total1Before / 1e18);

        vm.stopPrank();
        vm.startPrank(alice);

        uint256 swapAmount = 10e18;
        token0.mint(alice, swapAmount);
        token0.approve(address(swapRouter), swapAmount);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        vm.stopPrank();
        vm.startPrank(owner);

        console.log("\n=== After Price Change (Swap) ===");
        (uint256 total0AfterSwap, uint256 total1AfterSwap,,) = multiPositionManager.getTotalAmounts();
        uint256 percentageBeforeRebalance = (total0AfterSwap * 100) / (total0AfterSwap + total1AfterSwap);
        console.log("Token0:", total0AfterSwap / 1e18, "Token1:", total1AfterSwap / 1e18);
        console.log("Current ratio:", percentageBeforeRebalance, "% token0");

        (uint256[2][] memory outMin17, uint256[2][] memory inMin17) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
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
                tLeft: 1800,
                tRight: 1800,
                limitWidth: 60,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin17,
            inMin17
        );

        console.log("\n=== After Proportional Rebalance (0, 0) ===");
        (uint256 total0Final, uint256 total1Final,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0Final * 100) / (total0Final + total1Final);
        console.log("Token0:", total0Final / 1e18);
        console.log("Token1:", total1Final / 1e18);
        console.log("Final ratio token0:", actualPercentage0, "%");

        assertApproxEqRel(
            actualPercentage0, percentageBeforeRebalance, 0.03e18, "Should maintain proportions from holdings"
        );

        _visualizePositions("Proportional Distribution After Price Change");

        vm.stopPrank();
    }
}
