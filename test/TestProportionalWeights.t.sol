// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "forge-std/console.sol";

contract TestProportionalWeights is TestMultiPositionManager {
    GaussianStrategy gaussianStrategyLocal;
    UniformStrategy uniformStrategyLocal;

    function setUp() public override {
        super.setUp();
        gaussianStrategyLocal = new GaussianStrategy();
        uniformStrategyLocal = new UniformStrategy();
    }

    function test_ProportionalWeights_CalculatesCorrectly_70_30() public {
        uint256 amount0 = 70e18;
        uint256 amount1 = 30e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256 initialTotal0, uint256 initialTotal1,,) = multiPositionManager.getTotalAmounts();
        console.log("Initial - Token0:", initialTotal0 / 1e18, "Token1:", initialTotal1 / 1e18);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
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
            outMin,
            inMin
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("After Rebalance - Token0:", total0 / 1e18, "Token1:", total1 / 1e18);
        console.log("Allocation:", actualPercentage0, "% token0");

        assertApproxEqRel(actualPercentage0, 70, 0.02e18, "Should be ~70% token0");

        vm.stopPrank();
    }

    function test_ProportionalWeights_CalculatesCorrectly_40_60() public {
        uint256 amount0 = 40e18;
        uint256 amount1 = 60e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
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
            outMin,
            inMin
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("Allocation:", actualPercentage0, "% token0");

        assertApproxEqRel(actualPercentage0, 40, 0.03e18, "Should be ~40% token0");

        vm.stopPrank();
    }

    function test_ProportionalWeights_CalculatesCorrectly_90_10() public {
        uint256 amount0 = 90e18;
        uint256 amount1 = 10e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
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
            outMin,
            inMin
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("Allocation:", actualPercentage0, "% token0");

        assertApproxEqRel(actualPercentage0, 90, 0.02e18, "Should be ~90% token0");

        vm.stopPrank();
    }

    function test_ProportionalWeights_EdgeCase_ZeroBalance() public {
        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
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
            outMin,
            inMin
        );

        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage0 = (total0 * 100) / (total0 + total1);

        console.log("With zero idle balance - Allocation:", actualPercentage0, "% token0");

        assertApproxEqRel(actualPercentage0, 50, 0.02e18, "Should default to ~50% when both idle balances are zero");

        vm.stopPrank();
    }

    function test_ProportionalWeights_ConsistentAcrossStrategies() public {
        uint256 amount0 = 65e18;
        uint256 amount1 = 35e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0 * 3);
        token1.mint(owner, amount1 * 3);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);

        uint256[] memory percentages = new uint256[](3);
        address[3] memory strategies =
            [address(exponentialStrategy), address(gaussianStrategyLocal), address(uniformStrategyLocal)];
        string[3] memory strategyNames = ["Exponential", "Gaussian", "Uniform"];

        for (uint256 i = 0; i < strategies.length; i++) {
            multiPositionManager.deposit(amount0, amount1, owner, owner);

            (uint256[2][] memory outMin, uint256[2][] memory inMin) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: strategies[i],
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
                    strategy: strategies[i],
                    center: 0,
                    tLeft: 1800,
                    tRight: 1800,
                    limitWidth: 60,
                    weight0: 0,
                    weight1: 0,
                    useCarpet: false
                }),
                outMin,
                inMin
            );

            (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
            percentages[i] = (total0 * 100) / (total0 + total1);

            console.log(strategyNames[i], "Strategy - Allocation:", percentages[i], "% token0");

            assertApproxEqRel(percentages[i], 65, 0.02e18, "Should be ~65% token0 for all strategies");

            uint256 totalSupply = multiPositionManager.totalSupply();
            uint256[2][] memory withdrawOutMin =
                lens.getOutMinForShares(address(multiPositionManager), totalSupply, 500);
            multiPositionManager.withdraw(totalSupply, withdrawOutMin, false);
        }

        vm.stopPrank();
    }

    function test_ProportionalWeights_WithExistingPositions() public {
        uint256 initialAmount0 = 50e18;
        uint256 initialAmount1 = 50e18;

        vm.startPrank(owner);
        token0.mint(owner, initialAmount0);
        token1.mint(owner, initialAmount1);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);

        multiPositionManager.deposit(initialAmount0, initialAmount1, owner, owner);

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
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
            outMin,
            inMin
        );

        console.log("After initial 50/50 rebalance:");
        (uint256 total0Initial, uint256 total1Initial,,) = multiPositionManager.getTotalAmounts();
        console.log("  Token0:", total0Initial / 1e18, "Token1:", total1Initial / 1e18);

        uint256 additionalAmount0 = 60e18;
        uint256 additionalAmount1 = 20e18;
        token0.mint(owner, additionalAmount0);
        token1.mint(owner, additionalAmount1);

        multiPositionManager.deposit(additionalAmount0, additionalAmount1, owner, owner);

        console.log("After asymmetric deposit (60/20):");
        (uint256 total0BeforeRebalance, uint256 total1BeforeRebalance,,) = multiPositionManager.getTotalAmounts();
        uint256 expectedPercentage = (total0BeforeRebalance * 100) / (total0BeforeRebalance + total1BeforeRebalance);
        console.log("  Token0:", total0BeforeRebalance / 1e18, "Token1:", total1BeforeRebalance / 1e18);
        console.log("  Expected:", expectedPercentage, "% token0");

        (outMin, inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1800,
            ticksRight: 1800,
            limitWidth: 60,
            weight0: 0,
            weight1: 0,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        })); // Use proportional weights

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
            outMin,
            inMin
        );

        (uint256 total0Final, uint256 total1Final,,) = multiPositionManager.getTotalAmounts();
        uint256 actualPercentage = (total0Final * 100) / (total0Final + total1Final);

        console.log("After proportional rebalance:");
        console.log("  Token0:", total0Final / 1e18, "Token1:", total1Final / 1e18);
        console.log("  Actual:", actualPercentage, "% token0");

        assertApproxEqRel(actualPercentage, expectedPercentage, 0.02e18, "Should match current holdings proportion");

        vm.stopPrank();
    }
}
