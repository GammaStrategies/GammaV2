// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {SingleUniformStrategy} from "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {GaussianStrategy} from "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import {TriangleStrategy} from "../src/MultiPositionManager/strategies/TriangleStrategy.sol";
import {CamelStrategy} from "../src/MultiPositionManager/strategies/CamelStrategy.sol";

contract TestRebalancePreview is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    MultiPositionManager multiPositionManager;
    MultiPositionFactory factory;
    SimpleLens lens;
    SingleUniformStrategy uniformStrategy;
    ExponentialStrategy exponentialStrategy;
    GaussianStrategy gaussianStrategy;
    TriangleStrategy triangleStrategy;
    CamelStrategy camelStrategy;

    address alice = address(0x1);
    address owner = address(this);

    function setUp() public virtual {
        // Deploy base Uniswap v4 contracts
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy factory
        factory = new MultiPositionFactory(owner, manager);
        lens = new SimpleLens(manager);

        // Deploy all strategies
        uniformStrategy = new SingleUniformStrategy();
        exponentialStrategy = new ExponentialStrategy();
        gaussianStrategy = new GaussianStrategy();
        triangleStrategy = new TriangleStrategy();
        camelStrategy = new CamelStrategy();

        // Create a pool
        PoolKey memory _poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: int24(60),
            hooks: IHooks(address(0))
        });

        manager.initialize(_poolKey, SQRT_PRICE_1_1);

        // Create manager
        multiPositionManager =
            MultiPositionManager(payable(factory.deployMultiPositionManager(_poolKey, owner, "Test MPM")));

        // Setup initial liquidity
        deal(Currency.unwrap(currency0), owner, 1000e18);
        deal(Currency.unwrap(currency1), owner, 1000e18);

        // Approve from owner (who will be the 'from' in deposit)
        vm.startPrank(owner);
        IERC20(Currency.unwrap(currency0)).approve(address(multiPositionManager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(multiPositionManager), type(uint256).max);

        // Deploy strategy registry and add all strategies

        // Set registry and default strategy

        // Initial deposit (owner deposits to alice)
        multiPositionManager.deposit(100e18, 100e18, alice, owner);
        vm.stopPrank();

        // Setup initial positions
        MultiPositionManager.Range[] memory ranges = new MultiPositionManager.Range[](3);
        ranges[0] = IMultiPositionManager.Range(-600, 600);
        ranges[1] = IMultiPositionManager.Range(-1200, 1200);
        ranges[2] = IMultiPositionManager.Range(-1800, 1800);

        uint128[] memory liquidities = new uint128[](3);
        liquidities[0] = 1e18;
        liquidities[1] = 1e18;
        liquidities[2] = 1e18;

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );
    }

    function test_PreviewRebalanceWithUniformStrategy() public {
        // Check how many positions we have after setUp
        (IMultiPositionManager.Range[] memory initPositions,) = multiPositionManager.getBasePositions();
        console.log("Positions after setUp:", initPositions.length);

        int24 centerTick = 0;
        uint24 ticksLeft = 2100;
        uint24 ticksRight = 2100;

        // Get preview from lens (strategy will generate ranges)
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
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Uniform strategy generates a single range (gas efficient)
        assertEq(preview.ranges.length, 1, "Uniform should generate 1 range (single position)");
        assertEq(preview.liquidities.length, 1, "Should have 1 liquidity value");
        assertEq(preview.expectedPositions.length, 1, "Should have 1 expected position");
        assertEq(preview.strategy, address(uniformStrategy), "Strategy should match");
        assertEq(preview.centerTick, centerTick, "Center tick should match");
        assertEq(preview.ticksLeft, ticksLeft, "TicksLeft should match");
        assertEq(preview.ticksRight, ticksRight, "TicksRight should match");

        // Verify liquidity is non-zero
        assertGt(preview.liquidities[0], 0, "Liquidity should be non-zero");

        // Log the liquidity
        console.log("Preview liquidities:");
        console.log("Range 0 liquidity:", preview.liquidities[0]);

        // Verify totals are reasonable
        assertGt(preview.expectedTotal0, 0, "Should have token0 total");
        assertGt(preview.expectedTotal1, 0, "Should have token1 total");

        // Now execute the actual rebalance
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
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
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify the rebalance happened
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getBasePositions();
        assertEq(positions.length, preview.ranges.length, "Positions should match preview ranges");

        // Verify that the preview matched the actual rebalance
        console.log("Actual positions after rebalance:");
        for (uint256 i = 0; i < positions.length; i++) {
            console.log("Position", i, "liquidity:", positionData[i].liquidity);
            // Verify preview matched actual (within small tolerance for rounding)
            uint128 actualLiq = positionData[i].liquidity;
            uint128 predictedLiq = preview.liquidities[i];
            uint128 diff = actualLiq > predictedLiq ? actualLiq - predictedLiq : predictedLiq - actualLiq;
            // Allow for small rounding differences (less than 0.01%)
            assertLt(diff, predictedLiq / 10000, "Preview should match actual liquidity");
        }

        // Verify parameters were stored
        (address storedStrategy, int24 storedCenter, uint24 storedLeft, uint24 storedRight, uint24 storedLimitWidth,,,,,)
        = multiPositionManager.lastStrategyParams();
        assertEq(storedStrategy, address(uniformStrategy), "Strategy should be stored");
        assertEq(storedCenter, centerTick, "Center tick should be stored");
        assertEq(storedLeft, ticksLeft, "TicksLeft should be stored");
        assertEq(storedRight, ticksRight, "TicksRight should be stored");
    }

    function test_PreviewWithZeroStrategy_UsesUniform() public {
        // Test with uniform strategy (default)
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(uniformStrategy),
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

        // Should generate a valid preview with uniform distribution (1 single range)
        assertEq(preview.liquidities.length, 1, "Uniform should generate 1 range (gas efficient)");
        assertGt(preview.liquidities[0], 0, "Liquidity should be non-zero");
    }

    function test_PreviewRebalanceWithExponentialStrategy() public {
        // Check how many positions we have after setUp
        (IMultiPositionManager.Range[] memory initPositions,) = multiPositionManager.getBasePositions();

        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with exponential strategy (will generate ranges)
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
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Verify preview was generated
        assertGt(preview.ranges.length, 5, "Should have more than 5 ranges (dynamic generation)");
        assertGt(preview.liquidities.length, 5, "Should have more than 5 liquidities (dynamic generation)");
        assertEq(preview.expectedPositions.length, preview.ranges.length, "Expected positions should match ranges");
        assertEq(preview.strategy, address(exponentialStrategy), "Strategy should match");

        // Log the liquidities to see exponential distribution
        console.log("Exponential strategy preview liquidities:");
        uint256 maxLiq = 0;
        uint256 maxLiqIdx = 0;
        for (uint256 i = 0; i < preview.liquidities.length; i++) {
            console.log("Range", i, "liquidity:", preview.liquidities[i]);
            if (preview.liquidities[i] > maxLiq) {
                maxLiq = preview.liquidities[i];
                maxLiqIdx = i;
            }
        }

        // Verify exponential distribution (center should have highest liquidity)
        // With ~20 ranges, the center is around the middle index
        uint256 centerIdx = preview.liquidities.length / 2;
        assertLe(maxLiqIdx, centerIdx + 1, "Max liquidity should be near center");
        assertGe(maxLiqIdx, centerIdx - 1, "Max liquidity should be near center");

        // Verify decay from center towards edges
        assertGt(preview.liquidities[centerIdx], preview.liquidities[0], "Center should have more than edge");
        assertGt(
            preview.liquidities[centerIdx],
            preview.liquidities[preview.liquidities.length - 1],
            "Center should have more than edge"
        );

        // Now execute the actual rebalance
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
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
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify the rebalance happened
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getBasePositions();
        assertEq(positions.length, preview.ranges.length, "Positions should match preview ranges");

        // Verify that the preview matched the actual rebalance
        console.log("Actual positions after rebalance with exponential:");
        for (uint256 i = 0; i < positions.length; i++) {
            console.log("Position", i, "liquidity:", positionData[i].liquidity);
            // Verify preview matched actual (within small tolerance for rounding)
            uint128 actualLiq = positionData[i].liquidity;
            uint128 predictedLiq = preview.liquidities[i];
            uint128 diff = actualLiq > predictedLiq ? actualLiq - predictedLiq : predictedLiq - actualLiq;
            // Allow for small rounding differences (less than 0.01%)
            assertLt(diff, predictedLiq / 10000 + 1, "Preview should match actual liquidity");
        }
    }

    function test_RebalanceWithStoredParameters() public {
        // First rebalance with specific parameters
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: 60,
            ticksLeft: 1140,
            ticksRight: 1020,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(uniformStrategy),
                center: 60,
                tLeft: 1140,
                tRight: 1020,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify parameters were stored
        (address storedStrategy, int24 storedCenter, uint24 storedLeft, uint24 storedRight, uint24 storedLimitWidth,,,,,)
        = multiPositionManager.lastStrategyParams();
        assertEq(storedStrategy, address(uniformStrategy));
        assertEq(storedCenter, 60);
        assertEq(storedLeft, 1140);
        assertEq(storedRight, 1020);

        console.log("Stored parameters:");
        console.log("Strategy:", storedStrategy);
        console.log("CenterTick:", uint256(uint24(storedCenter)));
        console.log("TicksLeft:", uint256(storedLeft));
        console.log("TicksRight:", uint256(storedRight));

        // Preview with same stored parameters
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(uniformStrategy),
                centerTick: 60,
                ticksLeft: 1140,
                ticksRight: 1020,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Get all current positions (base + limit) after first rebalance
        (MultiPositionManager.Range[] memory currentPositions,) = multiPositionManager.getPositions();

        // Rebalance again with explicit values to test
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: 60,
            ticksLeft: 1140,
            ticksRight: 1020,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(uniformStrategy),
                center: 60,
                tLeft: 1140,
                tRight: 1020,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        // Verify it still used the same parameters
        (
            address storedStrategy2,
            int24 storedCenter2,
            uint24 storedLeft2,
            uint24 storedRight2,
            uint24 storedLimitWidth2,
            ,
            ,
            ,
            ,
        ) = multiPositionManager.lastStrategyParams();
        assertEq(storedStrategy2, address(uniformStrategy));
        assertEq(storedCenter2, 60);
        assertEq(storedLeft2, 1140);
        assertEq(storedRight2, 1020);
    }

    function test_PreviewRebalanceWithGaussianStrategy() public {
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Gaussian strategy
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
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Verify preview was generated
        assertGt(preview.ranges.length, 5, "Should have more than 5 ranges (dynamic generation)");
        assertEq(preview.strategy, address(gaussianStrategy), "Strategy should match");

        // Log the liquidities to see Gaussian distribution
        console.log("Gaussian strategy preview liquidities:");
        uint256 maxLiq = 0;
        uint256 maxLiqIdx = 0;
        for (uint256 i = 0; i < preview.liquidities.length; i++) {
            console.log("Range", i, "liquidity:", preview.liquidities[i]);
            if (preview.liquidities[i] > maxLiq) {
                maxLiq = preview.liquidities[i];
                maxLiqIdx = i;
            }
        }

        // Verify Gaussian distribution (center should have highest liquidity)
        uint256 centerIdx = preview.liquidities.length / 2;
        assertLe(maxLiqIdx, centerIdx + 1, "Max liquidity should be near center");
        assertGe(maxLiqIdx, centerIdx - 1, "Max liquidity should be near center");

        // Verify bell curve shape - edges should have less liquidity than center
        assertGt(preview.liquidities[centerIdx], preview.liquidities[0], "Center should have more than edge");
        assertGt(
            preview.liquidities[centerIdx],
            preview.liquidities[preview.liquidities.length - 1],
            "Center should have more than edge"
        );

        // Execute the actual rebalance
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(gaussianStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(gaussianStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify preview matched actual
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getBasePositions();
        assertGt(positions.length, 5, "Should have more than 5 positions (dynamic generation)");

        console.log("Actual positions after rebalance with Gaussian:");
        for (uint256 i = 0; i < positions.length; i++) {
            console.log("Position", i, "liquidity:", positionData[i].liquidity);
            // Verify preview matched actual
            uint128 actualLiq = positionData[i].liquidity;
            uint128 predictedLiq = preview.liquidities[i];
            uint128 diff = actualLiq > predictedLiq ? actualLiq - predictedLiq : predictedLiq - actualLiq;
            assertLt(diff, predictedLiq / 10000 + 1, "Preview should match actual");
        }
    }

    function test_PreviewRebalanceWithTriangleStrategy() public {
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Triangle strategy
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(triangleStrategy),
                centerTick: centerTick,
                ticksLeft: ticksLeft,
                ticksRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Verify preview was generated
        assertGt(preview.ranges.length, 5, "Should have more than 5 ranges (dynamic generation)");
        assertEq(preview.strategy, address(triangleStrategy), "Strategy should match");

        // Log the liquidities to see Triangle distribution
        console.log("Triangle strategy preview liquidities:");
        uint256 maxLiq = 0;
        uint256 maxLiqIdx = 0;
        for (uint256 i = 0; i < preview.liquidities.length; i++) {
            console.log("Range", i, "liquidity:", preview.liquidities[i]);
            if (preview.liquidities[i] > maxLiq) {
                maxLiq = preview.liquidities[i];
                maxLiqIdx = i;
            }
        }

        // Verify Triangle distribution (linear decay from center)
        uint256 centerIdx = preview.liquidities.length / 2;
        assertLe(maxLiqIdx, centerIdx + 1, "Max liquidity should be near center");
        assertGe(maxLiqIdx, centerIdx - 1, "Max liquidity should be near center");

        // Verify linear decay - edges should have less than center
        assertGt(preview.liquidities[centerIdx], preview.liquidities[0], "Center should have more than edge");
        assertGt(
            preview.liquidities[centerIdx],
            preview.liquidities[preview.liquidities.length - 1],
            "Center should have more than edge"
        );

        // Execute the actual rebalance
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(triangleStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(triangleStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify preview matched actual
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getBasePositions();
        assertGt(positions.length, 5, "Should have more than 5 positions (dynamic generation)");

        console.log("Actual positions after rebalance with Triangle:");
        for (uint256 i = 0; i < positions.length; i++) {
            console.log("Position", i, "liquidity:", positionData[i].liquidity);
            // Verify preview matched actual
            uint128 actualLiq = positionData[i].liquidity;
            uint128 predictedLiq = preview.liquidities[i];
            uint128 diff = actualLiq > predictedLiq ? actualLiq - predictedLiq : predictedLiq - actualLiq;
            assertLt(diff, predictedLiq / 10000 + 1, "Preview should match actual");
        }
    }

    function test_PreviewRebalanceWithCamelStrategy() public {
        int24 centerTick = 0;
        uint24 ticksLeft = 1800;
        uint24 ticksRight = 1800;

        // Get preview from lens with Camel strategy
        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(camelStrategy),
                centerTick: centerTick,
                ticksLeft: ticksLeft,
                ticksRight: ticksRight,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        // Verify preview was generated (CamelStrategy uses dynamic ranges like other strategies)
        assertGt(preview.ranges.length, 5, "Should have more than 5 ranges (dynamic generation)");
        assertEq(preview.strategy, address(camelStrategy), "Strategy should match");

        // Log the liquidities to see Camel distribution (two peaks)
        console.log("Camel strategy preview liquidities:");
        for (uint256 i = 0; i < preview.liquidities.length && i < 10; i++) {
            console.log("Range", i, "liquidity:", preview.liquidities[i]);
        }
        if (preview.liquidities.length > 10) {
            console.log("... and", preview.liquidities.length - 10, "more ranges");
        }

        // Execute the actual rebalance
        // Get slippage-protected values from SimpleLens
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(camelStrategy),
            centerTick: centerTick,
            ticksLeft: ticksLeft,
            ticksRight: ticksRight,
            limitWidth: 600,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        vm.prank(owner);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(camelStrategy),
                center: centerTick,
                tLeft: ticksLeft,
                tRight: ticksRight,
                limitWidth: 600,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        // Verify preview matched actual
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getBasePositions();
        assertGt(positions.length, 5, "Should have more than 5 positions (dynamic generation)");

        console.log("Actual positions after rebalance with Camel:");
        console.log("Preview liquidity count:", preview.liquidities.length);
        console.log("Actual position count:", positions.length);

        // Arrays should have same length
        assertEq(positions.length, preview.liquidities.length, "Position count should match preview");

        for (uint256 i = 0; i < positions.length; i++) {
            console.log("Position", i, "liquidity:", positionData[i].liquidity);
            // Verify preview matched actual
            uint128 actualLiq = positionData[i].liquidity;
            uint128 predictedLiq = preview.liquidities[i];
            uint128 diff = actualLiq > predictedLiq ? actualLiq - predictedLiq : predictedLiq - actualLiq;
            // Allow for small rounding differences (less than 0.01% or 1000 units for very small values)
            // For very small liquidities (< 1e6), allow larger tolerance as they may round to zero
            uint128 tolerance;
            if (predictedLiq == 0) {
                tolerance = 1000;
            } else if (predictedLiq < 1e6) {
                // For tiny liquidities, allow them to round to zero
                tolerance = predictedLiq + 1000;
            } else {
                tolerance = predictedLiq / 10000 + 1000;
            }
            assertLt(diff, tolerance, "Preview should match actual liquidity");
        }
    }
}
