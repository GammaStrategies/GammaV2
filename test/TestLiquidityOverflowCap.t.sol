// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {RebalanceLogicOldHarness} from "./utils/RebalanceLogicOld.sol";

/// @notice Harness to expose internal RebalanceLogic functions for testing
contract RebalanceLogicHarness {
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

contract TestLiquidityOverflowCap is Test {
    RebalanceLogicHarness harness;
    RebalanceLogicOldHarness oldHarness;

    function setUp() public {
        harness = new RebalanceLogicHarness();
        oldHarness = new RebalanceLogicOldHarness();
    }

    /// @notice Test calculateCurrentRangeExcess caps liquidity when price near lower tick
    function test_CalculateCurrentRangeExcess_CapsLiquidity_PriceNearLowerTick() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);
        // Price is just 1 unit above lower tick - denominator = 1
        uint160 sqrtPriceX96 = sqrtPriceLower + 1;

        // Verify sqrtPriceX96 corresponds to a valid tick (between lower and upper)
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Large token1 allocation that would overflow: 1e18 * Q96 / 1 = 7.9e46 >> uint128.max
        uint256 token1Allocation = 1e18;

        // Verify this would overflow without capping
        uint256 liquidityUncapped = FullMath.mulDiv(token1Allocation, FixedPoint96.Q96, 1);
        assertGt(liquidityUncapped, type(uint128).max, "Setup: should overflow uint128");

        // Calculate token0 needed for capped liquidity - provide MORE than needed so token1 is limiting
        (uint256 token0ForCapped,) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max
        );
        uint256 token0Allocation = token0ForCapped + 1e18; // Extra to ensure token1 is limiting

        // Build allocation data
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

        // Call the actual library function
        RebalanceLogic.ExcessData memory excess = harness.calculateCurrentRangeExcess(
            data,
            range,
            sqrtPriceX96
        );

        // Liquidity should be capped, so actualToken1 should match the capped-liquidity usage.
        (, uint256 expectedToken1Used) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            type(uint128).max
        );
        assertEq(excess.actualToken1, expectedToken1Used, "Should use capped liquidity");
        assertGt(excess.excessToken1, 0, "Should have excess token1 due to capping");
    }

    /// @notice Test mintFromAllocations caps liquidity for below-tick positions
    function test_MintFromAllocations_CapsLiquidity_BelowTick() public view {
        int24 lowerTick = -1000;
        int24 upperTick = -100;
        int24 currentTick = 0; // Position is below current tick

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        // For below-tick: liquidity = token1 * Q96 / (sqrtUpper - sqrtLower)
        // Make allocation large enough to overflow
        uint256 denominator = sqrtPriceUpper - sqrtPriceLower;
        // Need: token1 * Q96 / denom > uint128.max
        // So: token1 > uint128.max * denom / Q96
        uint256 token1Allocation = uint256(type(uint128).max) * denominator / FixedPoint96.Q96 + 1e18;

        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = 0;
        token1Allocs[0] = token1Allocation;

        RebalanceLogic.AllocationData memory data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: 0,
            totalToken1Needed: token1Allocation,
            currentRangeIndex: 0,
            currentTick: currentTick,
            hasCurrentRange: false
        });

        IMultiPositionManager.Range[] memory ranges = new IMultiPositionManager.Range[](1);
        ranges[0] = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        uint128[] memory liquidities = new uint128[](1);

        // Call the actual library function
        liquidities = harness.mintFromAllocations(liquidities, data, ranges, sqrtPriceX96);

        // Should be capped to uint128.max
        assertEq(liquidities[0], type(uint128).max, "Liquidity should be capped to uint128.max");
    }

    /// @notice Fuzz test: verify capping logic is correct for any liquidity value
    function testFuzz_CapLiquidity_CorrectBehavior(uint256 liquidity) public pure {
        uint128 capped = liquidity > type(uint128).max
            ? type(uint128).max
            : uint128(liquidity);

        if (liquidity > type(uint128).max) {
            assertEq(capped, type(uint128).max, "Should cap to max");
        } else {
            assertEq(uint256(capped), liquidity, "Should preserve value");
        }
    }

    /// @notice Test that limiting-token logic uses full uint256 precision before capping
    function test_LimitingTokenLogic_FullPrecision() public view {
        // Setup where full-precision token0Needed > token0Allocation (token0 limiting),
        // but capped-liquidity token0Needed < token0Allocation (would flip branch if truncated)
        (
            uint256 token0Allocation,
            uint256 token1Allocation,
            uint160 sqrtPriceX96,
            int24 currentTick
        ) = _setupLimitingTokenTest();

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
            lowerTick: 0,
            upperTick: 1000
        });

        RebalanceLogic.ExcessData memory excess = harness.calculateCurrentRangeExcess(
            data,
            range,
            sqrtPriceX96
        );

        // With full-precision comparison, token0 should be limiting, leaving excess token1.
        assertGt(excess.excessToken1, 0, "Should have excess token1 when token0 is limiting");
    }

    /// @notice Test old logic yields zero liquidity at the lower boundary
    function test_LowerBoundary_OldLogic_YieldsZeroLiquidity() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceX96 = sqrtPriceLower;

        uint256 token0Allocation = 1e18;
        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = token0Allocation;
        token1Allocs[0] = 0;

        RebalanceLogic.AllocationData memory data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: token0Allocation,
            totalToken1Needed: 0,
            currentRangeIndex: 0,
            currentTick: lowerTick,
            hasCurrentRange: true
        });

        IMultiPositionManager.Range memory range = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        RebalanceLogic.ExcessData memory excess = oldHarness.calculateCurrentRangeExcess(
            data,
            range,
            sqrtPriceX96
        );

        assertEq(excess.actualToken0, 0, "old logic: token0 unused at boundary");
        assertEq(excess.actualToken1, 0, "old logic: token1 unused at boundary");

        IMultiPositionManager.Range[] memory ranges = new IMultiPositionManager.Range[](1);
        ranges[0] = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        uint128[] memory liquidities = new uint128[](1);
        liquidities = oldHarness.mintFromAllocations(liquidities, data, ranges, sqrtPriceX96);

        assertEq(liquidities[0], 0, "old logic: liquidity zero at boundary");
    }

    /// @notice Test lower boundary uses token0-only liquidity in current range
    function test_LowerBoundary_UsesToken0_CurrentRange() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 sqrtPriceX96 = sqrtPriceLower;

        uint256 token0Allocation = 1e18;
        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = token0Allocation;
        token1Allocs[0] = 0;

        RebalanceLogic.AllocationData memory data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: token0Allocation,
            totalToken1Needed: 0,
            currentRangeIndex: 0,
            currentTick: lowerTick,
            hasCurrentRange: true
        });

        IMultiPositionManager.Range memory range = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        RebalanceLogic.ExcessData memory excess = harness.calculateCurrentRangeExcess(data, range, sqrtPriceX96);

        uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceLower, FixedPoint96.Q96);
        uint256 expectedLiquidity = FullMath.mulDiv(token0Allocation, intermediate, sqrtPriceUpper - sqrtPriceLower);
        uint128 expectedCapped =
            expectedLiquidity > type(uint128).max ? type(uint128).max : uint128(expectedLiquidity);

        (uint256 expectedToken0, uint256 expectedToken1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, expectedCapped
        );

        assertEq(excess.actualToken0, expectedToken0, "token0 used at lower boundary");
        assertEq(excess.actualToken1, expectedToken1, "token1 should be zero at boundary");
    }

    /// @notice Test mintFromAllocations uses token0-only liquidity at lower boundary
    function test_MintFromAllocations_LowerBoundary_UsesToken0() public view {
        int24 lowerTick = 0;
        int24 upperTick = 1000;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 sqrtPriceX96 = sqrtPriceLower;

        uint256 token0Allocation = 1e18;
        uint256[] memory token0Allocs = new uint256[](1);
        uint256[] memory token1Allocs = new uint256[](1);
        token0Allocs[0] = token0Allocation;
        token1Allocs[0] = 0;

        RebalanceLogic.AllocationData memory data = RebalanceLogic.AllocationData({
            token0Allocations: token0Allocs,
            token1Allocations: token1Allocs,
            totalToken0Needed: token0Allocation,
            totalToken1Needed: 0,
            currentRangeIndex: 0,
            currentTick: lowerTick,
            hasCurrentRange: true
        });

        IMultiPositionManager.Range[] memory ranges = new IMultiPositionManager.Range[](1);
        ranges[0] = IMultiPositionManager.Range({
            lowerTick: lowerTick,
            upperTick: upperTick
        });

        uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceLower, FixedPoint96.Q96);
        uint256 expectedLiquidity = FullMath.mulDiv(token0Allocation, intermediate, sqrtPriceUpper - sqrtPriceLower);
        uint128 expectedCapped =
            expectedLiquidity > type(uint128).max ? type(uint128).max : uint128(expectedLiquidity);

        uint128[] memory liquidities = new uint128[](1);
        liquidities = harness.mintFromAllocations(liquidities, data, ranges, sqrtPriceX96);

        assertEq(liquidities[0], expectedCapped, "liquidity from token0 at boundary");
    }

    /// @notice Helper to setup limiting-token test values (reduces stack depth)
    function _setupLimitingTokenTest() internal view returns (
        uint256 token0Allocation,
        uint256 token1Allocation,
        uint160 sqrtPriceX96,
        int24 currentTick
    ) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(1000);
        sqrtPriceX96 = sqrtPriceLower + 1; // tiny denominator
        currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        token1Allocation = uint256(type(uint128).max) + 1e18;
        uint256 liquidityFull = FullMath.mulDiv(token1Allocation, FixedPoint96.Q96, 1);
        uint256 liquidityCapped = type(uint128).max;

        uint256 denom = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
        uint256 numer = sqrtPriceUpper - sqrtPriceX96;

        uint256 token0NeededFull = FullMath.mulDiv(liquidityFull, numer, denom);
        uint256 token0NeededCapped = FullMath.mulDiv(liquidityCapped, numer, denom);

        token0Allocation = token0NeededCapped + 1;

        // Verify setup invariants
        require(token0NeededFull > token0Allocation, "Setup: full precision should be limiting");
        require(token0NeededCapped < token0Allocation, "Setup: capped would flip comparison");
    }
}
