// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {RebalanceLogicOldHarness} from "./utils/RebalanceLogicOld.sol";

contract RebalanceLogicEquivalenceHarness {
    function calculateCurrentRangeExcess(
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range memory range,
        uint160 sqrtPriceX96
    ) external pure returns (RebalanceLogic.ExcessData memory) {
        return RebalanceLogic.calculateCurrentRangeExcess(data, range, sqrtPriceX96);
    }

    function mintFromAllocations(
        uint128[] memory liquidities,
        RebalanceLogic.AllocationData memory data,
        IMultiPositionManager.Range[] memory baseRanges,
        uint160 sqrtPriceX96
    ) external pure returns (uint128[] memory) {
        RebalanceLogic.mintFromAllocations(liquidities, data, baseRanges, sqrtPriceX96);
        return liquidities;
    }
}

contract TestToken0NeededEquivalence is Test {
    RebalanceLogicEquivalenceHarness harness;
    RebalanceLogicOldHarness oldHarness;

    function setUp() public {
        harness = new RebalanceLogicEquivalenceHarness();
        oldHarness = new RebalanceLogicOldHarness();
    }

    function test_CalculateCurrentRangeExcess_MatchesOldFormula_WhenDenomNonZero() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(500);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);

        uint256 denom = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
        assertGt(denom, 0, "setup denom");

        uint256 token0Allocation = 1e18;
        uint256 token1Allocation = 2e18;

        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = token0Allocation;
        token1Allocs[0] = token1Allocation;

        RebalanceLogic.AllocationData memory data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: token0Allocation,
            totalToken1Needed: token1Allocation,
            currentRangeIndex: 0,
            currentTick: currentTick,
            hasCurrentRange: true
        });

        IMultiPositionManager.Range memory range = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        RebalanceLogic.ExcessData memory newExcess = harness.calculateCurrentRangeExcess(
            data,
            range,
            sqrtPriceX96
        );
        RebalanceLogic.ExcessData memory oldExcess = oldHarness.calculateCurrentRangeExcess(
            data,
            range,
            sqrtPriceX96
        );

        assertEq(newExcess.actualToken0, oldExcess.actualToken0, "actualToken0");
        assertEq(newExcess.actualToken1, oldExcess.actualToken1, "actualToken1");
        assertEq(newExcess.excessToken0, oldExcess.excessToken0, "excessToken0");
        assertEq(newExcess.excessToken1, oldExcess.excessToken1, "excessToken1");
    }

    function test_MintFromAllocations_MatchesOldFormula_WhenDenomNonZero() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(500);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);

        uint256 denom = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
        assertGt(denom, 0, "setup denom");

        (RebalanceLogic.AllocationData memory data, IMultiPositionManager.Range[] memory ranges) =
            _buildDataAndRanges(1e18, 2e18, lowerTick, upperTick, sqrtPriceX96);

        uint128[] memory newLiquidities = new uint128[](1);
        uint128[] memory oldLiquidities = new uint128[](1);

        newLiquidities = harness.mintFromAllocations(newLiquidities, data, ranges, sqrtPriceX96);
        oldLiquidities = oldHarness.mintFromAllocations(oldLiquidities, data, ranges, sqrtPriceX96);

        assertEq(newLiquidities[0], oldLiquidities[0], "liquidity");
    }

    function test_NoRevert_WhenDenomZero() public {
        int24 lowerTick = TickMath.MIN_TICK;
        int24 upperTick = lowerTick + 1;
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 sqrtPriceX96 = sqrtPriceLower + 1;

        uint256 denom = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
        assertEq(denom, 0, "setup denom");

        (RebalanceLogic.AllocationData memory data, IMultiPositionManager.Range[] memory ranges) =
            _buildDataAndRanges(1e6, 1e6, lowerTick, upperTick, sqrtPriceX96);
        IMultiPositionManager.Range memory range = ranges[0];

        harness.calculateCurrentRangeExcess(data, range, sqrtPriceX96);

        uint128[] memory liquidities = new uint128[](1);
        harness.mintFromAllocations(liquidities, data, ranges, sqrtPriceX96);

        vm.expectRevert();
        oldHarness.calculateCurrentRangeExcess(data, range, sqrtPriceX96);

        vm.expectRevert();
        oldHarness.mintFromAllocations(liquidities, data, ranges, sqrtPriceX96);
    }

    function _buildDataAndRanges(
        uint256 token0Allocation,
        uint256 token1Allocation,
        int24 lowerTick,
        int24 upperTick,
        uint160 sqrtPriceX96
    ) private pure returns (RebalanceLogic.AllocationData memory data, IMultiPositionManager.Range[] memory ranges) {
        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = token0Allocation;
        token1Allocs[0] = token1Allocation;

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: token0Allocation,
            totalToken1Needed: token1Allocation,
            currentRangeIndex: 0,
            currentTick: currentTick,
            hasCurrentRange: true
        });

        ranges = new IMultiPositionManager.Range[](1);
        ranges[0] = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });
    }
}
