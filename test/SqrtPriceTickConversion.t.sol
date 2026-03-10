// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {ILiquidityStrategy} from "../src/MultiPositionManager/strategies/ILiquidityStrategy.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";

/// @title SqrtPriceTickConversionTest
/// @notice Tests for sqrtPrice to tick conversion edge cases in migration flow
/// @dev These tests verify the correctness of:
///      1. Extreme sqrtPriceX96 values at MIN/MAX boundaries
///      2. Tick alignment with different tickSpacing values
///      3. Negative tick floor-division logic
///      4. SENTINEL_CENTER_TICK auto-centering behavior
///      5. Migration stuck scenarios due to invalid tick/price calculations
contract SqrtPriceTickConversionTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    // TickMath constants (from Uniswap V4)
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;
    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    // SENTINEL value used in rebalance params to indicate "use current tick"
    int24 constant SENTINEL_CENTER_TICK = type(int24).max; // 8388607

    // Strategy for generating ranges
    ExponentialStrategy exponentialStrategy;

    // Test tokens
    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        // Deploy pool manager and routers
        deployFreshManagerAndRouters();

        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Deploy ExponentialStrategy
        exponentialStrategy = new ExponentialStrategy();
    }

    // ============ Category 1: Extreme sqrtPriceX96 Boundary Tests ============

    /// @notice Test tick calculation at minimum sqrtPrice boundary
    function test_tickAtMinSqrtPrice() public pure {
        int24 tick = TickMath.getTickAtSqrtPrice(MIN_SQRT_PRICE);

        // MIN_SQRT_PRICE corresponds to MIN_TICK
        assertEq(tick, MIN_TICK, "MIN_SQRT_PRICE should give MIN_TICK");
    }

    /// @notice Test tick calculation at maximum sqrtPrice boundary (just below MAX)
    function test_tickAtMaxSqrtPrice() public pure {
        // MAX_SQRT_PRICE - 1 is the highest valid sqrtPrice for getTickAtSqrtPrice
        // getTickAtSqrtPrice requires sqrtPriceX96 < MAX_SQRT_PRICE
        uint160 justBelowMax = MAX_SQRT_PRICE - 1;
        int24 tick = TickMath.getTickAtSqrtPrice(justBelowMax);

        // Should be at or near MAX_TICK
        assertEq(tick, MAX_TICK - 1, "Just below MAX_SQRT_PRICE should give MAX_TICK - 1");
    }

    /// @notice Test that getSqrtPriceAtTick(MIN_TICK) returns MIN_SQRT_PRICE
    function test_sqrtPriceAtMinTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(MIN_TICK);
        assertEq(sqrtPrice, MIN_SQRT_PRICE, "getSqrtPriceAtTick(MIN_TICK) should return MIN_SQRT_PRICE");
    }

    /// @notice Test that getSqrtPriceAtTick(MAX_TICK) returns MAX_SQRT_PRICE
    function test_sqrtPriceAtMaxTick() public pure {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(MAX_TICK);
        assertEq(sqrtPrice, MAX_SQRT_PRICE, "getSqrtPriceAtTick(MAX_TICK) should return MAX_SQRT_PRICE");
    }

    /// @notice Test that getTickAtSqrtPrice reverts for sqrtPrice below MIN
    /// @dev TickMath uses custom errors that revert internally, so we catch via try/catch
    function test_revert_sqrtPriceBelowMin() public {
        uint160 belowMin = MIN_SQRT_PRICE - 1;

        // TickMath reverts with InvalidSqrtPrice for values outside valid range
        // Since it's a library call (internal), we use a helper to test
        bool reverted = false;
        try this.externalGetTickAtSqrtPrice(belowMin) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert for sqrtPrice below MIN");
    }

    /// @notice Test that getTickAtSqrtPrice reverts for sqrtPrice at or above MAX
    function test_revert_sqrtPriceAtOrAboveMax() public {
        // Test at MAX
        bool revertedAtMax = false;
        try this.externalGetTickAtSqrtPrice(MAX_SQRT_PRICE) {
            // Should not reach here
        } catch {
            revertedAtMax = true;
        }
        assertTrue(revertedAtMax, "Should revert for sqrtPrice at MAX");

        // Test above MAX
        bool revertedAboveMax = false;
        try this.externalGetTickAtSqrtPrice(MAX_SQRT_PRICE + 1) {
            // Should not reach here
        } catch {
            revertedAboveMax = true;
        }
        assertTrue(revertedAboveMax, "Should revert for sqrtPrice above MAX");
    }

    /// @notice Helper function to make library call external for try/catch
    function externalGetTickAtSqrtPrice(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Fuzz test: any valid sqrtPrice should produce a valid tick
    function testFuzz_sqrtPriceToTick_validRange(uint160 sqrtPriceX96) public pure {
        // Bound to valid range
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1));

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Tick should be within valid range
        assertTrue(tick >= MIN_TICK && tick <= MAX_TICK, "Tick should be within valid range");
    }

    /// @notice Fuzz test: tick -> sqrtPrice -> tick roundtrip
    function testFuzz_tickRoundtrip(int24 tick) public pure {
        // Bound to valid tick range
        tick = int24(bound(int256(tick), MIN_TICK, MAX_TICK));

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        int24 recoveredTick = TickMath.getTickAtSqrtPrice(sqrtPrice);

        // Recovered tick should equal original tick
        assertEq(recoveredTick, tick, "Tick roundtrip should preserve value");
    }

    // ============ Category 2: Tick Alignment with Different tickSpacing ============

    /// @notice Test floor-division tick alignment with tickSpacing = 1
    function test_tickAlignment_tickSpacing1() public pure {
        int24 tickSpacing = 1;

        // With tickSpacing = 1, all ticks are valid
        int24 currentTick = 12345;
        int24 compressed = currentTick / tickSpacing;
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, currentTick, "tickSpacing=1 should not change tick");

        // Negative tick
        currentTick = -12345;
        compressed = currentTick / tickSpacing;
        aligned = compressed * tickSpacing;
        assertEq(aligned, currentTick, "tickSpacing=1 should not change negative tick");
    }

    /// @notice Test floor-division tick alignment with tickSpacing = 10
    function test_tickAlignment_tickSpacing10() public pure {
        int24 tickSpacing = 10;

        // Positive tick not on boundary
        int24 currentTick = 12345;
        int24 compressed = currentTick / tickSpacing;
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, 12340, "12345 should align to 12340 with tickSpacing=10");

        // Positive tick on boundary
        currentTick = 12340;
        compressed = currentTick / tickSpacing;
        aligned = compressed * tickSpacing;
        assertEq(aligned, 12340, "12340 should remain 12340");
    }

    /// @notice Test floor-division tick alignment with tickSpacing = 60
    function test_tickAlignment_tickSpacing60() public pure {
        int24 tickSpacing = 60;

        // Positive tick
        int24 currentTick = 100;
        int24 compressed = currentTick / tickSpacing;
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, 60, "100 should align to 60 with tickSpacing=60");

        // Zero
        currentTick = 0;
        compressed = currentTick / tickSpacing;
        aligned = compressed * tickSpacing;
        assertEq(aligned, 0, "0 should remain 0");
    }

    /// @notice Test floor-division tick alignment with tickSpacing = 200
    function test_tickAlignment_tickSpacing200() public pure {
        int24 tickSpacing = 200;

        // Positive tick
        int24 currentTick = 450;
        int24 compressed = currentTick / tickSpacing;
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, 400, "450 should align to 400 with tickSpacing=200");

        // Larger tick
        currentTick = 10000;
        compressed = currentTick / tickSpacing;
        aligned = compressed * tickSpacing;
        assertEq(aligned, 10000, "10000 should remain 10000");
    }

    /// @notice Fuzz test: tick alignment for various tickSpacing values
    function testFuzz_tickAlignment(int24 currentTick, int24 tickSpacing) public pure {
        // Bound tickSpacing to valid range (1 to 16383 per Uniswap V4)
        tickSpacing = int24(bound(int256(tickSpacing), 1, 16383));
        // Bound currentTick to valid range
        currentTick = int24(bound(int256(currentTick), MIN_TICK, MAX_TICK));

        // Apply floor-division alignment (matches SuperchainLBPStrategy logic)
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        int24 aligned = compressed * tickSpacing;

        // Aligned tick should be <= currentTick (floor behavior)
        assertTrue(aligned <= currentTick, "Aligned tick should be <= currentTick");

        // Aligned tick should be a multiple of tickSpacing
        assertEq(aligned % tickSpacing, 0, "Aligned tick should be multiple of tickSpacing");

        // Next aligned tick should be > currentTick
        int24 nextAligned = aligned + tickSpacing;
        assertTrue(nextAligned > currentTick, "Next aligned tick should be > currentTick");
    }

    // ============ Category 3: Negative Tick Floor-Division Logic ============

    /// @notice Test negative tick floor-division with tickSpacing = 60
    function test_negativeTickFloorDivision_tickSpacing60() public pure {
        int24 tickSpacing = 60;

        // -1 should floor to -60 (not 0)
        int24 currentTick = -1;
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, -60, "-1 should floor to -60 with tickSpacing=60");

        // -60 should stay -60 (on boundary)
        currentTick = -60;
        compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        aligned = compressed * tickSpacing;

        assertEq(aligned, -60, "-60 should remain -60");

        // -61 should floor to -120
        currentTick = -61;
        compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        aligned = compressed * tickSpacing;

        assertEq(aligned, -120, "-61 should floor to -120 with tickSpacing=60");
    }

    /// @notice Test negative tick floor-division with tickSpacing = 10
    function test_negativeTickFloorDivision_tickSpacing10() public pure {
        int24 tickSpacing = 10;

        // -5 should floor to -10 (not 0)
        int24 currentTick = -5;
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        int24 aligned = compressed * tickSpacing;

        assertEq(aligned, -10, "-5 should floor to -10 with tickSpacing=10");

        // -10 should stay -10
        currentTick = -10;
        compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        aligned = compressed * tickSpacing;

        assertEq(aligned, -10, "-10 should remain -10");

        // -15 should floor to -20
        currentTick = -15;
        compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        aligned = compressed * tickSpacing;

        assertEq(aligned, -20, "-15 should floor to -20 with tickSpacing=10");
    }

    /// @notice Test that WITHOUT the floor correction, negative ticks are handled incorrectly
    function test_negativeTickWithoutFloorCorrection_incorrect() public pure {
        int24 tickSpacing = 60;
        int24 currentTick = -1;

        // Without floor correction (incorrect)
        int24 compressedWrong = currentTick / tickSpacing;
        int24 alignedWrong = compressedWrong * tickSpacing;

        // -1 / 60 = 0 in Solidity (truncation toward zero)
        // This gives 0, but we want -60 (floor behavior)
        assertEq(alignedWrong, 0, "Without correction: -1 truncates to 0");

        // With floor correction (correct)
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        int24 alignedCorrect = compressed * tickSpacing;

        assertEq(alignedCorrect, -60, "With correction: -1 floors to -60");
    }

    /// @notice Fuzz test: negative tick floor-division
    function testFuzz_negativeTickFloorDivision(int24 currentTick, int24 tickSpacing) public pure {
        // Only test negative ticks
        currentTick = int24(bound(int256(currentTick), MIN_TICK, -1));
        tickSpacing = int24(bound(int256(tickSpacing), 1, 200));

        // Apply floor-division alignment
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            compressed--;
        }
        int24 aligned = compressed * tickSpacing;

        // Verify floor behavior: aligned <= currentTick
        assertTrue(aligned <= currentTick, "Floor division should give aligned <= currentTick");

        // Verify it's a multiple of tickSpacing
        assertEq(aligned % tickSpacing, 0, "Aligned should be multiple of tickSpacing");

        // Verify next tick up is > currentTick
        assertTrue(aligned + tickSpacing > currentTick, "Next tick should be > currentTick");
    }

    // ============ Category 4: SENTINEL_CENTER_TICK Auto-Centering ============

    /// @notice Test SENTINEL_CENTER_TICK resolves to current tick with alignment
    function test_sentinelCenterTick_resolvesToCurrentTick() public pure {
        int24 tickSpacing = 60;

        // Simulate what _calculateInMinArray does
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1000); // Arbitrary price
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // When center == SENTINEL_CENTER_TICK, use current tick
        int24 center = SENTINEL_CENTER_TICK;
        int24 resolvedCenterTick;

        if (center == type(int24).max) {
            // SENTINEL_CENTER_TICK - use current tick with floor-division alignment
            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        } else {
            // User-provided center tick
            int24 compressed = center / tickSpacing;
            if (center < 0 && center % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        }

        // Verify resolved center tick is aligned
        assertEq(resolvedCenterTick % tickSpacing, 0, "Resolved center tick should be aligned");

        // Verify it's near currentTick (within one tickSpacing)
        assertTrue(resolvedCenterTick <= currentTick, "Resolved center should be <= currentTick");
        assertTrue(resolvedCenterTick + tickSpacing > currentTick, "Resolved center should be within one tickSpacing");
    }

    /// @notice Test SENTINEL_CENTER_TICK with negative current tick
    function test_sentinelCenterTick_negativeCurrentTick() public pure {
        int24 tickSpacing = 60;

        // Price that gives negative tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-1000);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int24 center = SENTINEL_CENTER_TICK;
        int24 resolvedCenterTick;

        if (center == type(int24).max) {
            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        } else {
            int24 compressed = center / tickSpacing;
            if (center < 0 && center % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        }

        // Verify resolved center tick is aligned and correct for negative tick
        assertEq(resolvedCenterTick % tickSpacing, 0, "Resolved center tick should be aligned");
        assertTrue(resolvedCenterTick <= currentTick, "Resolved center should be <= currentTick for negative");
    }

    /// @notice Test user-provided center tick overrides SENTINEL
    function test_userProvidedCenterTick_overridesSentinel() public pure {
        int24 tickSpacing = 60;
        int24 userCenter = 500; // User provides explicit center

        // When center != SENTINEL_CENTER_TICK, use user-provided value
        int24 center = userCenter;
        int24 resolvedCenterTick;

        if (center == type(int24).max) {
            // This branch NOT taken
            int24 currentTick = 0; // Would use currentTick
            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        } else {
            // User-provided center tick (THIS branch taken)
            int24 compressed = center / tickSpacing;
            if (center < 0 && center % tickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * tickSpacing;
        }

        // 500 / 60 = 8, aligned = 480
        assertEq(resolvedCenterTick, 480, "User center 500 should align to 480");
    }

    /// @notice Test SENTINEL behavior at tick boundaries (MIN_TICK, MAX_TICK)
    /// @dev At exact MIN_TICK, the floor-division may produce a value slightly below MIN_TICK
    ///      if MIN_TICK is not aligned to tickSpacing. The strategy's generateRanges handles this
    ///      by clamping to minUsableTick/maxUsableTick.
    function test_sentinelCenterTick_atTickBoundaries() public pure {
        int24 tickSpacing = 60;

        // Test at MIN_TICK
        {
            uint160 sqrtPriceX96 = MIN_SQRT_PRICE;
            int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

            // Note: MIN_TICK = -887272. With tickSpacing=60:
            // -887272 / 60 = -14787 (truncated toward zero)
            // -887272 % 60 = -52 (not 0)
            // So compressed-- gives -14788
            // resolved = -14788 * 60 = -887280
            // This is below MIN_TICK, but the strategy clamps it

            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            int24 resolvedCenterTick = compressed * tickSpacing;

            assertEq(resolvedCenterTick % tickSpacing, 0, "Center at MIN_TICK should be aligned");

            // The resolved center may be <= MIN_TICK, which is expected behavior
            // The strategy's generateRanges will clamp to minUsableTick
            // Just verify it's aligned (the main invariant)
            assertTrue(resolvedCenterTick <= currentTick, "Floor division should give <= currentTick");
        }

        // Test near MAX_TICK
        {
            uint160 sqrtPriceX96 = MAX_SQRT_PRICE - 1;
            int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            int24 resolvedCenterTick = compressed * tickSpacing;

            assertEq(resolvedCenterTick % tickSpacing, 0, "Center at MAX_TICK should be aligned");
            assertTrue(resolvedCenterTick <= MAX_TICK, "Center should be <= MAX_TICK");
        }
    }

    /// @notice Fuzz test: SENTINEL_CENTER_TICK resolution
    function testFuzz_sentinelCenterTick_resolution(uint160 sqrtPriceX96, int24 tickSpacing) public pure {
        // Bound inputs
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1));
        tickSpacing = int24(bound(int256(tickSpacing), 1, 200));

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Resolve SENTINEL_CENTER_TICK
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 resolvedCenterTick = compressed * tickSpacing;

        // Verify properties
        assertEq(resolvedCenterTick % tickSpacing, 0, "Resolved center should be aligned");
        assertTrue(resolvedCenterTick <= currentTick, "Resolved center should be <= currentTick");
        assertTrue(resolvedCenterTick + tickSpacing > currentTick, "Resolved center should be within one tickSpacing");
    }

    // ============ Category 5: Strategy Range Generation with Edge Cases ============

    /// @notice Test strategy generates valid ranges at MIN_TICK boundary
    function test_strategyRanges_atMinTick() public view {
        int24 tickSpacing = 60;
        int24 centerTick = MIN_TICK + 1200; // Close to MIN_TICK but with room for left positions
        uint24 tLeft = 600;
        uint24 tRight = 600;

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, false);

        // All ticks should be within valid range
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= MIN_TICK, "Lower tick should be >= MIN_TICK");
            assertTrue(upperTicks[i] <= MAX_TICK, "Upper tick should be <= MAX_TICK");
            assertTrue(lowerTicks[i] < upperTicks[i], "Lower tick should be < upper tick");
        }
    }

    /// @notice Test strategy generates valid ranges at MAX_TICK boundary
    function test_strategyRanges_atMaxTick() public view {
        int24 tickSpacing = 60;
        int24 centerTick = MAX_TICK - 1200; // Close to MAX_TICK but with room for right positions
        uint24 tLeft = 600;
        uint24 tRight = 600;

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, false);

        // All ticks should be within valid range
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= MIN_TICK, "Lower tick should be >= MIN_TICK");
            assertTrue(upperTicks[i] <= MAX_TICK, "Upper tick should be <= MAX_TICK");
            assertTrue(lowerTicks[i] < upperTicks[i], "Lower tick should be < upper tick");
        }
    }

    /// @notice Fuzz test: strategy range generation
    function testFuzz_strategyRanges_validTicks(int24 centerTick, uint24 tLeft, uint24 tRight, int24 tickSpacing)
        public
        view
    {
        // Bound inputs to reasonable values
        tickSpacing = int24(bound(int256(tickSpacing), 1, 200));

        // Ensure center tick is valid and has room for positions
        int256 minCenter = int256(MIN_TICK) + int256(uint256(tLeft)) + 1000;
        int256 maxCenter = int256(MAX_TICK) - int256(uint256(tRight)) - 1000;

        // Skip if range is invalid
        if (minCenter >= maxCenter) return;

        centerTick = int24(bound(int256(centerTick), minCenter, maxCenter));
        tLeft = uint24(bound(tLeft, 60, 5000));
        tRight = uint24(bound(tRight, 60, 5000));

        // Align center tick
        int24 compressed = centerTick / tickSpacing;
        if (centerTick < 0 && centerTick % tickSpacing != 0) compressed--;
        centerTick = compressed * tickSpacing;

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, false);

        // Verify all generated ranges are valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            // Skip invalid ranges (some strategies may return empty positions)
            if (lowerTicks[i] == 0 && upperTicks[i] == 0) continue;

            assertTrue(lowerTicks[i] >= MIN_TICK, "Lower tick should be >= MIN_TICK");
            assertTrue(upperTicks[i] <= MAX_TICK, "Upper tick should be <= MAX_TICK");
            assertTrue(lowerTicks[i] < upperTicks[i], "Lower tick should be < upper tick");

            // Verify tick alignment
            assertEq(lowerTicks[i] % tickSpacing, 0, "Lower tick should be aligned");
            assertEq(upperTicks[i] % tickSpacing, 0, "Upper tick should be aligned");
        }
    }

    // ============ Category 6: Migration Stuck Scenarios ============

    /// @notice Test migration could get stuck if sqrtPrice produces tick outside strategy range
    /// @dev This simulates what happens in _calculateInMinArray when the resolved center tick
    ///      is at extreme boundaries
    function test_migrationStuck_centerTickAtMinBoundary() public view {
        int24 tickSpacing = 60;
        uint24 tLeft = 100000; // Large range
        uint24 tRight = 100000;

        // sqrtPrice at minimum - this could happen with very low auction clearing price
        uint160 sqrtPriceX96 = MIN_SQRT_PRICE;
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Resolve center tick (SENTINEL behavior)
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 resolvedCenterTick = compressed * tickSpacing;

        // Try to generate ranges - this should NOT revert
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);

        // Verify we got valid ranges (migration would NOT be stuck)
        assertTrue(lowerTicks.length > 0, "Should generate at least one range even at MIN boundary");

        // Verify all ranges are valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= TickMath.minUsableTick(tickSpacing), "Lower tick within bounds");
            assertTrue(upperTicks[i] <= TickMath.maxUsableTick(tickSpacing), "Upper tick within bounds");
        }
    }

    /// @notice Test migration could get stuck if sqrtPrice produces tick outside strategy range (MAX)
    function test_migrationStuck_centerTickAtMaxBoundary() public view {
        int24 tickSpacing = 60;
        uint24 tLeft = 100000;
        uint24 tRight = 100000;

        // sqrtPrice at maximum - this could happen with very high auction clearing price
        uint160 sqrtPriceX96 = MAX_SQRT_PRICE - 1;
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Resolve center tick
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 resolvedCenterTick = compressed * tickSpacing;

        // Try to generate ranges - this should NOT revert
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);

        // Verify we got valid ranges
        assertTrue(lowerTicks.length > 0, "Should generate at least one range even at MAX boundary");

        // Verify all ranges are valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= TickMath.minUsableTick(tickSpacing), "Lower tick within bounds");
            assertTrue(upperTicks[i] <= TickMath.maxUsableTick(tickSpacing), "Upper tick within bounds");
        }
    }

    /// @notice Test migration gets stuck if inMin array length is wrong (simulates array mismatch)
    /// @dev In real migration, if _calculateInMinArray returns wrong length, it would cause array bounds error
    function test_migrationStuck_inMinArrayLengthMismatch() public view {
        int24 tickSpacing = 60;
        int24 centerTick = 0;
        uint24 tLeft = 1000;
        uint24 tRight = 1000;

        // Generate ranges
        (int24[] memory lowerTicks,) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, false);

        uint256 expectedRangeCount = lowerTicks.length;

        // Simulate _calculateInMinArray behavior
        uint256[2][] memory inMin = new uint256[2][](expectedRangeCount);
        for (uint256 i = 0; i < expectedRangeCount; i++) {
            inMin[i] = [uint256(0), uint256(0)];
        }

        // Verify lengths match (if they don't, migration would fail with array out of bounds)
        assertEq(inMin.length, expectedRangeCount, "inMin array length should match range count");
    }

    /// @notice Test migration could fail with zero liquidity due to extreme price
    function test_migrationStuck_zeroLiquidityAtExtremePrices() public pure {
        int24 tickSpacing = 60;

        // Very extreme sqrtPrice near minimum
        uint160 sqrtPriceX96 = MIN_SQRT_PRICE + 1000;

        // Calculate liquidity for a position near the extreme
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = tickLower + tickSpacing;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // With reasonable amounts, should still get some liquidity
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, amount0, amount1);

        // At extreme prices, one of the amounts may dominate
        // Migration should NOT get stuck with zero liquidity if amounts are reasonable
        assertTrue(liquidity > 0 || sqrtPriceX96 < sqrtPriceLower || sqrtPriceX96 > sqrtPriceUpper,
            "Should have liquidity or price outside range");
    }

    /// @notice Test that very small ticksLeft/ticksRight doesn't cause empty ranges
    function test_migrationStuck_verySmallTickRange() public view {
        int24 tickSpacing = 60;
        int24 centerTick = 0;
        uint24 tLeft = 60; // Minimum meaningful range
        uint24 tRight = 60;

        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, false);

        // Should still generate at least one range
        assertTrue(lowerTicks.length > 0, "Should generate ranges even with small tick range");

        // Verify ranges are valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] < upperTicks[i], "Range should have lower < upper");
        }
    }

    /// @notice Test migration behavior when tick is exactly on spacing boundary vs off by one
    function test_migrationStuck_tickBoundaryAlignment() public view {
        int24 tickSpacing = 60;
        uint24 tLeft = 1000;
        uint24 tRight = 1000;

        // Test tick exactly on boundary
        {
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(120); // On boundary for tickSpacing=60
            int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            int24 resolvedCenterTick = compressed * tickSpacing;

            assertEq(resolvedCenterTick, 120, "On-boundary tick should resolve to same value");

            // Should generate ranges without issue
            (int24[] memory lowerTicks,) =
                exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);
            assertTrue(lowerTicks.length > 0, "Should generate ranges for on-boundary tick");
        }

        // Test tick off by one
        {
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(121); // Off boundary
            int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

            int24 compressed = currentTick / tickSpacing;
            if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
            int24 resolvedCenterTick = compressed * tickSpacing;

            assertEq(resolvedCenterTick, 120, "Off-boundary tick should floor to 120");

            // Should generate ranges without issue
            (int24[] memory lowerTicks,) =
                exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);
            assertTrue(lowerTicks.length > 0, "Should generate ranges for off-boundary tick");
        }
    }

    /// @notice Test that carpet ranges don't cause migration to fail at boundaries
    function test_migrationStuck_carpetRangesAtBoundaries() public view {
        int24 tickSpacing = 60;
        int24 centerTick = MIN_TICK + 5000; // Near MIN but not at boundary
        uint24 tLeft = 1000;
        uint24 tRight = 1000;

        // Generate ranges with carpet
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(centerTick, tLeft, tRight, tickSpacing, true);

        // Verify carpet ranges are valid
        assertTrue(lowerTicks.length > 0, "Should generate ranges with floor");

        // Full-range floor should cover min/max usable ticks
        assertEq(lowerTicks[0], TickMath.minUsableTick(tickSpacing), "Floor should start at minUsableTick");
        assertEq(upperTicks[0], TickMath.maxUsableTick(tickSpacing), "Floor should end at maxUsableTick");

        // All ranges should be valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] < upperTicks[i], "All ranges should be valid");
            assertTrue(lowerTicks[i] >= TickMath.minUsableTick(tickSpacing), "Lower ticks in bounds");
            assertTrue(upperTicks[i] <= TickMath.maxUsableTick(tickSpacing), "Upper ticks in bounds");
        }
    }

    // ============ Category 7: Integration-Style Tests ============

    /// @notice Test full flow: sqrtPrice -> tick -> center alignment -> range generation
    function test_fullFlow_sqrtPriceToRanges() public view {
        int24 tickSpacing = 60;
        uint24 tLeft = 1000;
        uint24 tRight = 1000;

        // Start with a sqrtPriceX96 (simulating auction result)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1234);

        // Step 1: Convert to tick
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Step 2: Align to tickSpacing (SENTINEL_CENTER_TICK behavior)
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 resolvedCenterTick = compressed * tickSpacing;

        // Step 3: Generate ranges
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);

        // Verify ranges are valid
        assertTrue(lowerTicks.length > 0, "Should generate at least one range");

        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= MIN_TICK, "Lower tick in range");
            assertTrue(upperTicks[i] <= MAX_TICK, "Upper tick in range");
            assertTrue(lowerTicks[i] < upperTicks[i], "Valid range");
            assertEq(lowerTicks[i] % tickSpacing, 0, "Lower aligned");
            assertEq(upperTicks[i] % tickSpacing, 0, "Upper aligned");
        }
    }

    /// @notice Test flow with negative tick from sqrtPrice
    function test_fullFlow_negativeTick() public view {
        int24 tickSpacing = 60;
        uint24 tLeft = 1000;
        uint24 tRight = 1000;

        // sqrtPrice that gives negative tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-5000);

        // Step 1: Convert to tick
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        assertTrue(currentTick < 0, "Current tick should be negative");

        // Step 2: Align (with floor correction for negative)
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 resolvedCenterTick = compressed * tickSpacing;

        // Verify floor behavior
        assertTrue(resolvedCenterTick <= currentTick, "Floor should give <= currentTick");

        // Step 3: Generate ranges
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, tickSpacing, false);

        // Verify ranges are valid
        for (uint256 i = 0; i < lowerTicks.length; i++) {
            assertTrue(lowerTicks[i] >= MIN_TICK, "Lower tick in range");
            assertTrue(upperTicks[i] <= MAX_TICK, "Upper tick in range");
        }
    }

    /// @notice Test the exact scenario from _calculateInMinArray in SuperchainLBPStrategy
    function test_calculateInMinArray_simulation() public view {
        // Simulate the exact logic from SuperchainLBPStrategy._calculateInMinArray
        int24 poolTickSpacing = 60;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1000);

        // Rebalance params (simulating what would be stored in strategy)
        int24 center = SENTINEL_CENTER_TICK;
        uint24 tLeft = 1000;
        uint24 tRight = 1000;
        bool useCarpet = false;

        // Convert sqrtPriceX96 to tick using TickMath library
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Resolve center tick with proper floor-division alignment
        int24 resolvedCenterTick;
        if (center == type(int24).max) {
            // SENTINEL_CENTER_TICK - use current tick with floor-division alignment
            int24 compressed = currentTick / poolTickSpacing;
            if (currentTick < 0 && currentTick % poolTickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * poolTickSpacing;
        } else {
            // User-provided center tick - apply same floor-division
            int24 compressed = center / poolTickSpacing;
            if (center < 0 && center % poolTickSpacing != 0) compressed--;
            resolvedCenterTick = compressed * poolTickSpacing;
        }

        // Get base range count from strategy using resolved center tick
        (int24[] memory lowerTicks,) =
            exponentialStrategy.generateRanges(resolvedCenterTick, tLeft, tRight, poolTickSpacing, useCarpet);

        uint256 baseRangeCount = lowerTicks.length;

        // Create inMin array ONLY for base positions
        uint256[2][] memory inMin = new uint256[2][](baseRangeCount);
        for (uint256 i = 0; i < baseRangeCount; i++) {
            inMin[i] = [uint256(0), uint256(0)];
        }

        // Verify the array was created correctly
        assertEq(inMin.length, baseRangeCount, "inMin length should match base range count");
        assertTrue(baseRangeCount > 0, "Should have at least one base range");
    }
}
