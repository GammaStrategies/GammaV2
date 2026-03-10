// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";

contract TestSingleSidedWeights is TestMultiPositionManager {
    function setUp() public override {
        super.setUp();
    }

    function test_100PercentToken0Weight() public {
        console.log("\n=== Testing 100% Token0 Weight ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with 100% weight to token0
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 120,
            weight0: 1e18,
            weight1: 0,
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
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 120,
                weight0: 1e18, // 100% token0
                weight1: 0, // 0% token1
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Get positions and check distribution
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("Total positions:", positions.length);

        // Check base positions
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();
        console.log("\nBase positions (should have minimal/zero liquidity in ranges spanning current price):");
        for (uint256 i = 0; i < basePositionsLength; i++) {
            console.log("Position", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Liquidity:", positionData[i].liquidity);
        }

        // Check limit positions (should contain most liquidity)
        console.log("\nLimit positions (should contain most token0):");
        for (uint256 i = basePositionsLength; i < positions.length; i++) {
            console.log("Position", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Liquidity:", positionData[i].liquidity);
        }

        vm.stopPrank();
    }

    function test_100PercentToken1Weight() public {
        console.log("\n=== Testing 100% Token1 Weight ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with 100% weight to token1
        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 120,
            weight0: 0,
            weight1: 1e18,
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
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 120,
                weight0: 0, // 0% token0
                weight1: 1e18, // 100% token1
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        // Get positions and check distribution
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        console.log("Total positions:", positions.length);

        // Check base positions
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();
        console.log("\nBase positions (should have minimal/zero liquidity in ranges spanning current price):");
        for (uint256 i = 0; i < basePositionsLength; i++) {
            console.log("Position", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Liquidity:", positionData[i].liquidity);
        }

        // Check limit positions (should contain most liquidity)
        console.log("\nLimit positions (should contain most token1):");
        for (uint256 i = basePositionsLength; i < positions.length; i++) {
            console.log("Position", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Liquidity:", positionData[i].liquidity);
        }

        vm.stopPrank();
    }

    function test_ExtremeWeightImbalance_95_5() public {
        console.log("\n=== Testing 95/5 Weight Split (Previously Would Fail) ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with 95/5 split (would have been blocked before)
        (uint256[2][] memory outMin3, uint256[2][] memory inMin3) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 120,
            weight0: 0.95e18,
            weight1: 0.05e18,
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
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 120,
                weight0: 0.95e18, // 95%
                weight1: 0.05e18, // 5%
                useCarpet: false
            }),
            outMin3,
            inMin3
        );

        console.log("Successfully rebalanced with 95/5 weight split!");

        vm.stopPrank();
    }
}
