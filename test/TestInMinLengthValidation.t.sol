// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import {InitialDepositLens} from "../src/MultiPositionManager/periphery/InitialDepositLens.sol";

contract TestInMinLengthValidation is TestMultiPositionManager {
    function test_SimpleLensInMinLengthMatchesBaseRanges_WithCarpet() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            1200,
            1200,
            120,
            0.5e18,
            0.5e18,
            true,
            false,
            500,
            500
        );
        outMin; // silence unused warning

        (int24[] memory lowerTicks,) = exponentialStrategy.generateRanges(0, 1200, 1200, key.tickSpacing, true);
        assertEq(inMin.length, lowerTicks.length, "SimpleLens inMin length must match base ranges");
    }

    function test_InitialDepositLensInMinLengthMatchesBaseRanges_WithCarpet() public view {
        (uint256[2][] memory inMin,) = initialDepositLens.previewCustomInitialDepositAndRebalance(
            key,
            InitialDepositLens.CustomInitialDepositParams({
                strategyAddress: address(exponentialStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                deposit0: 100 ether,
                deposit1: 100 ether,
                maxSlippageBps: 500
            })
        );

        (int24[] memory lowerTicks,) = exponentialStrategy.generateRanges(0, 1200, 1200, key.tickSpacing, true);
        assertEq(inMin.length, lowerTicks.length, "InitialDepositLens inMin length must match base ranges");
    }

    function test_RebalanceWithCarpet_RevertsOnMismatchedNonEmptyInMinLength() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            1200,
            1200,
            120,
            0.5e18,
            0.5e18,
            true,
            false,
            500,
            500
        );

        uint256[2][] memory badInMin = new uint256[2][](inMin.length + 1);
        for (uint256 i = 0; i < inMin.length; i++) {
            badInMin[i] = inMin[i];
        }

        vm.expectRevert();
        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin,
            badInMin
        );
    }

    function test_RebalanceWithCarpet_AllowsEmptyInMinAsExplicitNoProtection() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        (uint256[2][] memory outMin,) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            1200,
            1200,
            120,
            0.5e18,
            0.5e18,
            true,
            false,
            500,
            500
        );

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1200,
                tRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true
            }),
            outMin,
            new uint256[2][](0)
        );

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        assertGt(ranges.length, 0, "Rebalance with empty inMin should still create positions");
    }

    function test_RebalanceSucceeds_WithCarpet_UsingSimpleLensInMin() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1200,
            tRight: 1200,
            limitWidth: 120,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true
        });

        (uint256[2][] memory outMin, uint256[2][] memory inMin) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
            1200,
            1200,
            120,
            0.5e18,
            0.5e18,
            true,
            false,
            500,
            500
        );

        vm.prank(owner);
        multiPositionManager.rebalance(params, outMin, inMin);

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        assertGt(ranges.length, 0, "Rebalance with SimpleLens inMin should create positions");
    }

    function test_RebalanceSucceeds_WithCarpet_UsingInitialDepositLensInMin() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);
        vm.stopPrank();

        (uint256[2][] memory inMin,) = initialDepositLens.previewCustomInitialDepositAndRebalance(
            key,
            InitialDepositLens.CustomInitialDepositParams({
                strategyAddress: address(exponentialStrategy),
                centerTick: 0,
                ticksLeft: 1200,
                ticksRight: 1200,
                limitWidth: 120,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: true,
                deposit0: amount0,
                deposit1: amount1,
                maxSlippageBps: 500
            })
        );

        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1200,
            tRight: 1200,
            limitWidth: 120,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true
        });

        vm.prank(owner);
        multiPositionManager.rebalance(params, new uint256[2][](0), inMin);

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        assertGt(ranges.length, 0, "Rebalance with InitialDepositLens inMin should create positions");
    }
}
