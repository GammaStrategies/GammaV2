// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import {UniformStrategy} from "../src/MultiPositionManager/strategies/UniformStrategy.sol";

contract TestRebalanceSlippage is TestMultiPositionManager {
    UniformStrategy public uniformStrategy;

    function setUp() public override {
        super.setUp();
        uniformStrategy = new UniformStrategy();
    }

    function test_RebalanceWithSlippageProtection_Success() public {
        console.log("\n=== Testing Rebalance With Slippage Protection - Success Path ===\n");

        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1000, 1000, 120, 0.5e18, 0.5e18, false, false, 500, 500
        );

        console.log("Calculated outMin length:", outMin.length);
        console.log("Calculated inMin length:", inMin.length);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("Rebalance succeeded with slippage protection");

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        console.log("Final token0:", total0);
        console.log("Final token1:", total1);

        vm.stopPrank();
    }

    function test_RebalanceSlippageViolation_AfterSwap() public {
        console.log("\n=== Testing Slippage Violation After Swap (Single-Tick Strategy) ===\n");

        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // First do an initial rebalance to create positions with liquidity
        (uint256[2][] memory outMinInitial, uint256[2][] memory inMinInitial) = SimpleLensInMin
            .getOutMinAndInMinForRebalance(
            multiPositionManager, address(uniformStrategy), 0, 60, 60, 0, 0.5e18, 0.5e18, false, false, 500, 500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(uniformStrategy),
                center: 0,
                tLeft: 60,
                tRight: 60,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinInitial,
            inMinInitial
        );

        console.log("Initial rebalance completed");

        // Now calculate slippage values for a SECOND rebalance at current tick
        int24 centerAtCurrentTick = multiPositionManager.CENTER_AT_CURRENT_TICK();

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: centerAtCurrentTick,
            ticksLeft: 60,
            ticksRight: 60,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 10,
            maxSlippageInMin: 10,
            deductFees: false
        }));

        console.log("Calculated slippage-protected values for second rebalance");
        console.log("outMin length:", outMin.length);
        console.log("inMin length:", inMin.length);

        vm.stopPrank();

        int24 currentTick = multiPositionManager.currentTick();
        console.log("Current tick before swap:");
        console.logInt(currentTick);

        // Mint and approve tokens for the swap
        token0.mint(address(this), 10 ether);
        token0.approve(address(swapRouter), 10 ether);

        // Small swap to move price down a few ticks
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-200)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        currentTick = multiPositionManager.currentTick();
        console.log("Current tick after swap:");
        console.logInt(currentTick);

        // Try to rebalance with stale slippage values - should revert
        vm.expectRevert();
        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(uniformStrategy),
                center: centerAtCurrentTick,
                tLeft: 60,
                tRight: 60,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("Rebalance correctly reverted due to slippage violation");
    }

    function test_RebalanceWithNoExistingPositions() public {
        console.log("\n=== Testing Rebalance With No Existing Positions ===\n");

        uint256 amount0 = 50 ether;
        uint256 amount1 = 50 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 800, 800, 60, 0.5e18, 0.5e18, false, false, 500, 500
        );

        console.log("outMin length (no positions):", outMin.length);
        console.log("inMin length:", inMin.length);

        assertEq(outMin.length, 0, "outMin should be empty when no positions exist");
        assertGt(inMin.length, 0, "inMin should have values for new positions");

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 800,
                tRight: 800,
                limitWidth: 60,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("First rebalance succeeded with empty outMin");

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        assertGt(ranges.length, 0, "Should have created positions");

        vm.stopPrank();
    }

    function test_RebalanceWithTightSlippage() public {
        console.log("\n=== Testing Rebalance With Tight Slippage (50 BPS) ===\n");

        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1200, 1200, 120, 0.5e18, 0.5e18, false, false, 50, 50
        );

        console.log("Calculated with 50 BPS (0.5%) slippage");
        console.log("inMin length:", inMin.length);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("Rebalance succeeded with tight slippage tolerance");

        vm.stopPrank();
    }

    function test_RebalanceWithCarpet_SlippageProtection() public {
        console.log("\n=== Testing Rebalance With Carpet and Slippage Protection ===\n");

        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1500, 1500, 120, 0.5e18, 0.5e18, true, false, 500, 500
        );

        console.log("Calculated slippage values with carpet enabled");
        console.log("inMin length:", inMin.length);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1500,
                tRight: 1500,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin,
            inMin
        );

        console.log("Rebalance with carpet succeeded");

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();

        int24 minUsable = TickMath.minUsableTick(60);
        int24 maxUsable = TickMath.maxUsableTick(60);

        bool hasFloor = false;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == minUsable && ranges[i].upperTick == maxUsable) {
                hasFloor = true;
                break;
            }
        }

        assertTrue(hasFloor, "Should have a full-range floor position");
        console.log("Full-range floor verified");

        vm.stopPrank();
    }

    function test_RebalanceSequential_SlippageProtection() public {
        console.log("\n=== Testing Sequential Rebalances With Slippage Protection ===\n");

        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin1, uint256[2][] memory inMin1) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 800, 800, 60, 0.5e18, 0.5e18, false, false, 500, 500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 800,
                tRight: 800,
                limitWidth: 60,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin1,
            inMin1
        );

        console.log("First rebalance completed");

        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1200, 1200, 120, 0.5e18, 0.5e18, false, false, 500, 500
        );

        console.log("Second rebalance outMin length:", outMin2.length);
        console.log("Second rebalance inMin length:", inMin2.length);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        console.log("Second rebalance completed with slippage protection");

        vm.stopPrank();
    }
}
