// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {UniformStrategy} from "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import "forge-std/console.sol";

contract TestSingleTickStrategy is TestMultiPositionManager {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    UniformStrategy uniformStrategy;

    function setUp() public override {
        super.setUp();
        uniformStrategy = new UniformStrategy();
    }

    function test_SingleTick_AtInitialTick0() public {
        console.log("\n=== Single Tick Strategy: Initial Tick 0 ===");

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        int24 currentTick = multiPositionManager.currentTick();
        console.log("Current tick before rebalance:", _tickToString(currentTick));

        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(uniformStrategy),
                centerTick: currentTick,
                ticksLeft: 0,
                ticksRight: 60,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("\n--- Preview Results ---");
        console.log("Number of ranges:", preview.ranges.length);
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            console.log("Range", i);
            console.log("  Lower:", _tickToString(preview.ranges[i].lowerTick));
            console.log("  Upper:", _tickToString(preview.ranges[i].upperTick));
            console.log("  Liquidity:", uint256(preview.liquidities[i]));
        }

        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: currentTick,
            ticksLeft: 0,
            ticksRight: 60,
            limitWidth: 0,
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
                strategy: address(uniformStrategy),
                center: currentTick,
                tLeft: 0,
                tRight: 60,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        console.log("\n--- After Rebalance ---");
        _visualizePositions();

        vm.stopPrank();
    }

    function test_SingleTick_AfterTinySwap() public {
        console.log("\n=== Single Tick Strategy: After Tiny Swap (TickSpacing=60) ===");

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
            ticksLeft: 300,
            ticksRight: 300,
            limitWidth: 0,
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
                tLeft: 300,
                tRight: 300,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin
        );

        token0.mint(owner, 0.001e18);
        token0.approve(address(swapRouter), 0.001e18);

        PoolKey memory key = multiPositionManager.poolKey();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int24 currentTick = multiPositionManager.currentTick();
        console.log("Current tick after swap:", _tickToString(currentTick));

        int24 alignedTick = (currentTick / 60) * 60;
        console.log("Aligned tick:", _tickToString(alignedTick));

        (SimpleLensInMin.RebalancePreview memory preview,,) = lens.previewRebalanceWithStrategyAndCarpet(
            multiPositionManager,
            SimpleLens.PreviewRebalanceParams({
                strategyAddress: address(uniformStrategy),
                centerTick: alignedTick,
                ticksLeft: 0,
                ticksRight: 60,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false,
                maxSlippageOutMin: 0,
                maxSlippageInMin: 0
            })
        );

        console.log("\n--- Preview Results ---");
        console.log("Number of ranges:", preview.ranges.length);
        for (uint256 i = 0; i < preview.ranges.length; i++) {
            console.log("Range", i);
            console.log("  Lower:", _tickToString(preview.ranges[i].lowerTick));
            console.log("  Upper:", _tickToString(preview.ranges[i].upperTick));
            console.log("  Liquidity:", uint256(preview.liquidities[i]));
        }

        uint256 baseLen = multiPositionManager.basePositionsLength();
        uint256 limitLen = multiPositionManager.limitPositionsLength();
        console.log("\n--- Before Rebalance ---");
        console.log("Base positions length:", baseLen);
        console.log("Limit positions length:", limitLen);

        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(uniformStrategy),
            centerTick: alignedTick,
            ticksLeft: 0,
            ticksRight: 60,
            limitWidth: 0,
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
                strategy: address(uniformStrategy),
                center: alignedTick,
                tLeft: 0,
                tRight: 60,
                limitWidth: 0,
                weight0: 0,
                weight1: 0,
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        console.log("\n--- After Rebalance ---");
        console.log("Base positions length:", multiPositionManager.basePositionsLength());
        console.log("Limit positions length:", multiPositionManager.limitPositionsLength());
        _visualizePositions();

        vm.stopPrank();
    }

    function test_SingleTick_TickSpacing1_AfterSwap() public {
        console.log("\n=== Single Tick Strategy: TickSpacing=1 After Swap ===");

        PoolKey memory pool1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        manager.initialize(pool1, SQRT_PRICE_1_1);

        MultiPositionManager mpm1 = new MultiPositionManager(
            IPoolManager(address(manager)), pool1, owner, address(mockFactory), "Test Position", "TPOS", 10
        );

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(mpm1), amount0);
        token1.approve(address(mpm1), amount1);

        mpm1.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin1, uint256[2][] memory inMin1) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm1,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 300,
            ticksRight: 300,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        mpm1.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 300,
                tRight: 300,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin1,
            inMin1
        );

        token0.mint(owner, 0.001e18);
        token0.approve(address(swapRouter), 0.001e18);

        swapRouter.swap(
            pool1,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int24 alignedTick = (mpm1.currentTick() / 1) * 1;
        {
            (uint256[2][] memory calculatedOutMin11, uint256[2][] memory inMin11) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm1,
            strategyAddress: address(uniformStrategy),
            centerTick: alignedTick,
            ticksLeft: 0,
            ticksRight: 1,
            limitWidth: 0,
            weight0: 0,
            weight1: 0,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));
            mpm1.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(uniformStrategy),
                    center: alignedTick,
                    tLeft: 0,
                    tRight: 1,
                    limitWidth: 0,
                    weight0: 0,
                    weight1: 0,
                    useCarpet: false
                }),
                new uint256[2][](mpm1.basePositionsLength() + mpm1.limitPositionsLength()),
                inMin11
            );
        }

        vm.stopPrank();
    }

    function test_AutoCenterAtCurrentTick_AfterSwap() public {
        console.log("\n=== Auto-Center at Current Tick: Using CENTER_AT_CURRENT_TICK Sentinel (TickSpacing=1) ===");

        PoolKey memory pool1 = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        manager.initialize(pool1, SQRT_PRICE_1_1);

        MultiPositionManager mpm1 = new MultiPositionManager(
            IPoolManager(address(manager)), pool1, owner, address(mockFactory), "Test Position", "TPOS", 10
        );

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(mpm1), amount0);
        token1.approve(address(mpm1), amount1);

        mpm1.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm1,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 300,
            ticksRight: 300,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        mpm1.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 300,
                tRight: 300,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin2,
            inMin2
        );

        console.log("\n--- Before Swap ---");
        int24 tickBeforeSwap = mpm1.currentTick();
        console.log("Current tick:", _tickToString(tickBeforeSwap));

        token0.mint(owner, 1e18);
        token0.approve(address(swapRouter), 1e18);

        swapRouter.swap(
            pool1,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        int24 tickAfterSwap = mpm1.currentTick();
        {
            (uint256[2][] memory calculatedOutMin12, uint256[2][] memory inMin12) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm1,
            strategyAddress: address(uniformStrategy),
            centerTick: mpm1.CENTER_AT_CURRENT_TICK(),
            ticksLeft: 0,
            ticksRight: 1,
            limitWidth: 0,
            weight0: 0,
            weight1: 0,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));
            mpm1.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(uniformStrategy),
                    center: mpm1.CENTER_AT_CURRENT_TICK(),
                    tLeft: 0,
                    tRight: 1,
                    limitWidth: 0,
                    weight0: 0,
                    weight1: 0,
                    useCarpet: false
                }),
                new uint256[2][](mpm1.basePositionsLength() + mpm1.limitPositionsLength()),
                inMin12
            );
        }
        {
            (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
                mpm1.getPositions();
            assertEq(
                positions[0].lowerTick, (tickAfterSwap / 1) * 1, "Position should be centered at aligned current tick"
            );
            assertEq(positions[0].upperTick, (tickAfterSwap / 1) * 1 + 1, "Upper tick should be one tick spacing above");
            assertTrue(positionData[0].liquidity > 0, "Position should have non-zero liquidity");
        }

        vm.stopPrank();
    }

    function _visualizePositions() internal view {
        _visualizePositionsForManager(multiPositionManager);
    }

    function _visualizePositionsForManager(MultiPositionManager mpm) internal view {
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            mpm.getPositions();

        int24 currentTick = mpm.currentTick();
        uint256 baseCount = mpm.basePositionsLength();

        console.log("Current Tick:", _tickToString(currentTick));
        console.log("Total positions:", positions.length);
        console.log("Base positions:", baseCount);
        console.log("");

        for (uint256 i = 0; i < positions.length; i++) {
            string memory posType = i < baseCount ? "Base" : "Limit";
            console.log(posType, i, ":");
            console.log("  Lower:", _tickToString(positions[i].lowerTick));
            console.log("  Upper:", _tickToString(positions[i].upperTick));
            console.log("  Liquidity:", uint256(positionData[i].liquidity));
            console.log("  Token0:", _formatAmount(positionData[i].amount0));
            console.log("  Token1:", _formatAmount(positionData[i].amount1));
        }

        (uint256 total0, uint256 total1,,) = mpm.getTotalAmounts();
        console.log("\nTotal Token0:", _formatAmount(total0));
        console.log("Total Token1:", _formatAmount(total1));
    }

    function _tickToString(int24 tick) internal pure override returns (string memory) {
        if (tick < 0) {
            return string(abi.encodePacked("-", _uintToString(uint24(-tick))));
        }
        return _uintToString(uint24(tick));
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

        uint256 etherAmount = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e16;

        return
            string(abi.encodePacked(_uintToString(etherAmount), ".", decimal < 10 ? "0" : "", _uintToString(decimal)));
    }
}
