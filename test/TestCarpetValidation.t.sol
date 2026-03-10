// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";

contract TestCarpetValidation is TestMultiPositionManager {
    function setUp() public override {
        super.setUp();
    }

    function _roundDownTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed -= 1;
        }
        return compressed * tickSpacing;
    }

    function test_FloorAllowsSingleToken() public {
        console.log("\n=== Testing Full-Range Floor With Single Token ===\n");

        // Only deposit token0, no token1
        uint256 amount0 = 100 ether;
        uint256 amount1 = 0;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token0.approve(address(multiPositionManager), amount0);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0,
                weight0: 0.8e18, // Weights don't matter - no token1 available
                weight1: 0.2e18,
                useCarpet: true // Full-range floor enabled but only have token0
            }),
            new uint256[2][](0),
            new uint256[2][](0)
        );

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        int24 maxUsable = TickMath.maxUsableTick(multiPositionManager.poolKey().tickSpacing);
        bool hasOneSidedFloor = false;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].upperTick == maxUsable) {
                hasOneSidedFloor = true;
                break;
            }
        }
        assertTrue(hasOneSidedFloor, "Expected a token0-sided floor range at max usable tick");

        vm.stopPrank();
    }

    function test_FloorAllowsSingleToken1() public {
        console.log("\n=== Testing Full-Range Floor With Single Token1 ===\n");

        // Only deposit token1, no token0
        uint256 amount0 = 0;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token1.mint(owner, amount1);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0,
                weight0: 0.2e18, // Weights don't matter - no token0 available
                weight1: 0.8e18,
                useCarpet: true // Full-range floor enabled but only have token1
            }),
            new uint256[2][](0),
            new uint256[2][](0)
        );

        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory data) =
            multiPositionManager.getPositions();
        int24 minUsable = TickMath.minUsableTick(multiPositionManager.poolKey().tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(multiPositionManager.poolKey().tickSpacing);
        int24 alignedDown = _roundDownTick(multiPositionManager.currentTick(), multiPositionManager.poolKey().tickSpacing);

        bool hasOneSidedFloor = false;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == minUsable && ranges[i].upperTick == alignedDown) {
                hasOneSidedFloor = true;
                assertEq(data[i].amount0, 0, "Token1-sided floor should have zero token0");
                break;
            }
            assertFalse(
                ranges[i].lowerTick == minUsable && ranges[i].upperTick == maxUsable,
                "Full-range floor should be replaced by one-sided range"
            );
        }
        assertTrue(hasOneSidedFloor, "Expected a token1-sided floor range at min usable tick");

        vm.stopPrank();
    }

    function test_CarpetWorksWithBothTokens() public {
        console.log("\n=== Testing Carpet Mode With Both Tokens ===\n");

        // Deposit both tokens
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with carpet mode - should succeed even with extreme weights
        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1000, 1000, 0, 0.99e18, 0.01e18, true, false, 500, 500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0,
                weight0: 0.99e18, // Very lopsided weights but both tokens available
                weight1: 0.01e18,
                useCarpet: true
            }),
            outMin,
            inMin
        );

        console.log("Successfully rebalanced with carpet and both tokens");

        vm.stopPrank();
    }

    function test_NoCarpetAllowsSingleToken() public {
        console.log("\n=== Testing Non-Carpet Mode Allows Single Token ===\n");

        // Only deposit token0
        uint256 amount0 = 100 ether;
        uint256 amount1 = 0;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token0.approve(address(multiPositionManager), amount0);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance without carpet mode - should succeed
        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 1000, 1000, 120, 1e18, 0, false, false, 500, 500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 120,
                weight0: 1e18, // 100% token0
                weight1: 0,
                useCarpet: false // Carpet disabled - single token is fine
            }),
            outMin,
            inMin
        );

        console.log("Successfully rebalanced without carpet using only token0");

        vm.stopPrank();
    }

    function test_CarpetWithExtremeWeights() public {
        console.log("\n=== Testing Carpet Mode With Extreme Weights ===\n");

        // Deposit both tokens but use extreme weights
        uint256 amount0 = 1 ether; // Small amount of token0
        uint256 amount1 = 100 ether; // Large amount of token1

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with carpet and extreme weights matching token ratio
        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager, address(exponentialStrategy), 0, 500, 500, 0, 0.01e18, 0.99e18, true, false, 500, 500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 500,
                tRight: 500,
                limitWidth: 0,
                weight0: 0.01e18, // 1% weight for token0
                weight1: 0.99e18, // 99% weight for token1
                useCarpet: true // Carpet works as long as both tokens present
            }),
            outMin,
            inMin
        );

        console.log("Successfully created carpet with extreme weights but both tokens present");

        vm.stopPrank();
    }
}
