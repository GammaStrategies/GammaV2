// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {PositionLogic} from "../src/MultiPositionManager/libraries/PositionLogic.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import {LiquidityAmountsCapped} from "../src/MultiPositionManager/libraries/LiquidityAmountsCapped.sol";
import {PoolManagerUtils} from "../src/MultiPositionManager/libraries/PoolManagerUtils.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

contract PoolManagerUtilsHarness {
    function capLiquidityForModify(uint128 liquidity) external pure returns (uint128) {
        return PoolManagerUtils._capLiquidityForModify(liquidity);
    }
}

contract TestLiquidityOverflowRuntimeFix is Test {
    using SafeCast for uint256;

    PoolManagerUtilsHarness internal poolUtilsHarness;

    function setUp() public {
        poolUtilsHarness = new PoolManagerUtilsHarness();
    }

    function rawGetLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1);
    }

    function castToInt128(uint256 x) external pure returns (int128) {
        return x.toInt128();
    }

    function test_OverflowingAmount1_IsCappedInsteadOfReverting() public {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(1);
        uint160 sqrtPriceX96 = sqrtPriceUpper; // token1-only branch

        uint256 overflowAmount1 =
            FullMath.mulDiv(uint256(type(uint128).max), sqrtPriceUpper - sqrtPriceLower, FixedPoint96.Q96) + 1;

        vm.expectRevert();
        this.rawGetLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, 0, overflowAmount1);

        uint128 capped = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
            sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, 0, overflowAmount1
        );
        assertEq(capped, type(uint128).max, "capped liquidity should saturate at uint128 max");
    }

    function test_AddLimitPositionsAndInMin_DoesNotRevertOnOverflowingRemainders() public {
        IMultiPositionManager.Range[] memory baseRanges = new IMultiPositionManager.Range[](1);
        baseRanges[0] = IMultiPositionManager.Range({lowerTick: -100, upperTick: 100});

        uint128[] memory baseLiquidities = new uint128[](1);
        baseLiquidities[0] = 0;

        int24 currentTick = 0;
        int24 tickSpacing = 1;
        uint24 limitWidth = 10;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        uint256 overflowAmount0;
        uint256 overflowAmount1;
        {
            (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit) =
                PositionLogic.calculateLimitRanges(limitWidth, baseRanges, tickSpacing, currentTick);

            uint160 lowerLimitSqrtLower = TickMath.getSqrtPriceAtTick(lowerLimit.lowerTick);
            uint160 lowerLimitSqrtUpper = TickMath.getSqrtPriceAtTick(lowerLimit.upperTick);
            uint160 upperLimitSqrtLower = TickMath.getSqrtPriceAtTick(upperLimit.lowerTick);
            uint160 upperLimitSqrtUpper = TickMath.getSqrtPriceAtTick(upperLimit.upperTick);

            overflowAmount1 = FullMath.mulDiv(
                uint256(type(uint128).max), uint256(lowerLimitSqrtUpper - lowerLimitSqrtLower), FixedPoint96.Q96
            ) + 1;

            uint256 upperIntermediate =
                FullMath.mulDiv(uint256(upperLimitSqrtLower), uint256(upperLimitSqrtUpper), FixedPoint96.Q96);
            overflowAmount0 = FullMath.mulDiv(
                uint256(type(uint128).max), uint256(upperLimitSqrtUpper - upperLimitSqrtLower), upperIntermediate
            ) + 1;

            vm.expectRevert();
            this.rawGetLiquidity(sqrtPriceX96, lowerLimitSqrtLower, lowerLimitSqrtUpper, 0, overflowAmount1);

            vm.expectRevert();
            this.rawGetLiquidity(sqrtPriceX96, upperLimitSqrtLower, upperLimitSqrtUpper, overflowAmount0, 0);
        }

        SimpleLensInMin.LimitPositionsParams memory params = SimpleLensInMin.LimitPositionsParams({
            limitWidth: limitWidth,
            currentTick: currentTick,
            tickSpacing: tickSpacing,
            maxSlippageBps: 500,
            sqrtPriceX96: sqrtPriceX96,
            totalAmount0: overflowAmount0,
            totalAmount1: overflowAmount1
        });

        (
            IMultiPositionManager.Range[] memory allRanges,
            uint128[] memory allLiquidities,
            uint256[2][] memory inMin
        ) = SimpleLensInMin.addLimitPositionsAndCalculateInMin(baseRanges, baseLiquidities, params);

        assertEq(allRanges.length, 3, "expected base + 2 limit ranges");
        assertEq(allLiquidities.length, 3, "expected base + 2 liquidity slots");
        assertEq(allLiquidities[1], type(uint128).max, "lower limit liquidity should be capped");
        assertEq(allLiquidities[2], type(uint128).max, "upper limit liquidity should be capped");
        assertEq(inMin.length, 1, "inMin is returned only for base ranges");
    }

    function test_PoolManagerUtils_RuntimeLiquidityDelta_IsClampedToInt128Max() public view {
        uint128 runtimeCap = poolUtilsHarness.capLiquidityForModify(type(uint128).max);
        assertEq(runtimeCap, uint128(type(int128).max), "runtime liquidity delta cap must be int128 max");
    }

    function test_RuntimeClamp_Prevents_ToInt128BoundaryRevert() public {
        uint128 aboveInt128Max = uint128(type(int128).max) + 1;

        // This mirrors the old on-chain failure mode at `liquidity.toInt128()`.
        vm.expectRevert();
        this.castToInt128(uint256(aboveInt128Max));

        // New path clamps first, so cast succeeds.
        uint128 clamped = poolUtilsHarness.capLiquidityForModify(aboveInt128Max);
        int128 delta = this.castToInt128(uint256(clamped));
        assertEq(delta, type(int128).max, "clamped liquidity must cast cleanly to int128");
    }
}
