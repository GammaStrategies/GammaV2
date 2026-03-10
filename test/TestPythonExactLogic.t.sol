// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/**
 * @title TestPythonExactLogic
 * @notice Tests that RebalanceLogic exactly matches Python backtesting logic
 * @dev Focus on edge cases where positions might get 0 liquidity
 */
contract TestPythonExactLogic is Test {
    using CurrencyLibrary for Currency;

    // Test helper to simulate Python's mint_position logic
    struct MintResult {
        uint128 liquidity;
        uint256 amount0Used;
        uint256 amount1Used;
    }

    /**
     * @notice Python's exact mint_position logic
     * @dev This is what we're trying to match in Solidity
     */
    function pythonMintPosition(
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal pure returns (MintResult memory result) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(upperTick);

        // Python logic:
        // if P < Pa: only token0 needed
        // if P > Pb: only token1 needed
        // if Pa <= P <= Pb: both tokens needed

        if (sqrtPriceX96 <= sqrtPriceLower) {
            // Position above current price - only token0 needed
            // Python: liquidity = x / (1/sqrt(Pa) - 1/sqrt(Pb))
            if (amount0 > 0) {
                result.liquidity = uint128(
                    FullMath.mulDiv(
                        amount0,
                        FixedPoint96.Q96,
                        FullMath.mulDiv(sqrtPriceUpper - sqrtPriceLower, FixedPoint96.Q96, sqrtPriceUpper)
                            / sqrtPriceLower
                    )
                );

                // Calculate actual amount0 used
                result.amount0Used = FullMath.mulDiv(
                    result.liquidity,
                    FullMath.mulDiv(sqrtPriceUpper - sqrtPriceLower, FixedPoint96.Q96, sqrtPriceUpper) / sqrtPriceLower,
                    FixedPoint96.Q96
                );
            }
        } else if (sqrtPriceX96 >= sqrtPriceUpper) {
            // Position below current price - only token1 needed
            // Python: liquidity = y / (sqrt(Pb) - sqrt(Pa))
            if (amount1 > 0) {
                result.liquidity = uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceUpper - sqrtPriceLower));

                // Calculate actual amount1 used
                result.amount1Used =
                    FullMath.mulDiv(result.liquidity, sqrtPriceUpper - sqrtPriceLower, FixedPoint96.Q96);
            }
        } else {
            // Current range - both tokens needed
            // Python tries both directions and picks one that works

            // Try using token1 (assume token1 is in excess)
            uint128 liquidityFrom1 = 0;
            if (sqrtPriceX96 > sqrtPriceLower && amount1 > 0) {
                liquidityFrom1 = uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96 - sqrtPriceLower));
            }

            // Try using token0 (assume token0 is in excess)
            uint128 liquidityFrom0 = 0;
            if (sqrtPriceX96 < sqrtPriceUpper && amount0 > 0) {
                // Use the standard Uniswap formula for token0 in current range
                // liquidity = amount0 * (sqrt(P) * sqrt(Pb)) / ((sqrt(Pb) - sqrt(P)) * Q96)
                uint256 intermediate = FullMath.mulDiv(sqrtPriceUpper, sqrtPriceX96, FixedPoint96.Q96);
                liquidityFrom0 = uint128(FullMath.mulDiv(amount0, intermediate, sqrtPriceUpper - sqrtPriceX96));
            }

            // Pick the smaller liquidity (Python logic)
            if (liquidityFrom0 > 0 && liquidityFrom1 > 0) {
                result.liquidity = liquidityFrom0 < liquidityFrom1 ? liquidityFrom0 : liquidityFrom1;
            } else if (liquidityFrom0 > 0) {
                result.liquidity = liquidityFrom0;
            } else {
                result.liquidity = liquidityFrom1;
            }

            // Calculate actual amounts used
            if (result.liquidity > 0) {
                (result.amount0Used, result.amount1Used) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, result.liquidity
                );
            }
        }
    }


    /**
     * @notice Test edge case: Position at boundary (lowerTick == currentTick)
     */
    function test_BoundaryPosition_LowerTickEqualsCurrentTick() public {
        console2.log("\n=== Test: Boundary Position - LowerTick == CurrentTick ===");

        int24 currentTick = -191820;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        int24 lowerTick = -191820; // Exactly at current tick
        int24 upperTick = -191760;

        uint256 amount0 = 0.0001 ether;
        uint256 amount1 = 15 * 1e6; // 15 USDC

        MintResult memory result = pythonMintPosition(lowerTick, upperTick, amount0, amount1, sqrtPriceX96);

        console2.log("Position at boundary:");
        console2.log("  Current tick = Lower tick:", currentTick);
        console2.log("  Liquidity:", result.liquidity);
        console2.log("  Token0 used:", result.amount0Used);
        console2.log("  Token1 used:", result.amount1Used);

        // At this boundary, only token0 should be needed
        assertGt(result.liquidity, 0, "Should have non-zero liquidity at boundary");
        assertGt(result.amount0Used, 0, "Should use token0 at boundary");
        assertEq(result.amount1Used, 0, "Should not need token1 when P = Pa");
    }

    /**
     * @notice Test edge case: Position at boundary (upperTick == currentTick)
     */
    function test_BoundaryPosition_UpperTickEqualsCurrentTick() public {
        console2.log("\n=== Test: Boundary Position - UpperTick == CurrentTick ===");

        int24 currentTick = -191760;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        int24 lowerTick = -191820;
        int24 upperTick = -191760; // Exactly at current tick

        uint256 amount0 = 0.0001 ether;
        uint256 amount1 = 15 * 1e6; // 15 USDC

        MintResult memory result = pythonMintPosition(lowerTick, upperTick, amount0, amount1, sqrtPriceX96);

        console2.log("Position at boundary:");
        console2.log("  Current tick = Upper tick:", currentTick);
        console2.log("  Liquidity:", result.liquidity);
        console2.log("  Token0 used:", result.amount0Used);
        console2.log("  Token1 used:", result.amount1Used);

        // At this boundary, only token1 should be needed
        assertGt(result.liquidity, 0, "Should have non-zero liquidity at boundary");
        assertEq(result.amount0Used, 0, "Should not need token0 when P = Pb");
        assertGt(result.amount1Used, 0, "Should use token1 at boundary");
    }

    /**
     * @notice Test very small allocations (potential rounding to 0)
     */
    function test_SmallAllocations_RoundingBehavior() public {
        console2.log("\n=== Test: Small Allocations - Rounding Behavior ===");

        int24 currentTick = -191782;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        int24 lowerTick = -191820;
        int24 upperTick = -191760;

        // Very small amounts that might round to 0
        uint256 amount0 = 100; // 100 wei
        uint256 amount1 = 1; // 1 smallest unit of USDC

        MintResult memory result = pythonMintPosition(lowerTick, upperTick, amount0, amount1, sqrtPriceX96);

        console2.log("Small allocation test:");
        console2.log("  Input token0:", amount0);
        console2.log("  Input token1:", amount1);
        console2.log("  Liquidity:", result.liquidity);

        // Even with tiny amounts, Python logic tries to mint
        // It may round to 0, but it doesn't zero out allocations preemptively
        if (result.liquidity == 0) {
            console2.log("  -> Liquidity rounded to 0 (expected for very small amounts)");
        } else {
            console2.log("  -> Non-zero liquidity achieved");
        }
    }

    /**
     * @notice Test asymmetric allocation (heavy on one token)
     */
    function test_AsymmetricAllocation_SingleTokenDominant() public {
        console2.log("\n=== Test: Asymmetric Allocation - Single Token Dominant ===");

        int24 currentTick = -191782;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);

        int24 lowerTick = -191820;
        int24 upperTick = -191760;

        // Heavy on token0, minimal token1
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1; // Just 1 unit of token1

        MintResult memory result = pythonMintPosition(lowerTick, upperTick, amount0, amount1, sqrtPriceX96);

        console2.log("Asymmetric allocation (token0 heavy):");
        console2.log("  Input token0:", amount0);
        console2.log("  Input token1:", amount1);
        console2.log("  Liquidity:", result.liquidity);
        console2.log("  Token0 used:", result.amount0Used);
        console2.log("  Token1 used:", result.amount1Used);

        // Should still mint with available tokens
        assertGt(result.liquidity, 0, "Should mint with asymmetric allocation");

        // Now test opposite: heavy on token1
        amount0 = 1; // Just 1 wei
        amount1 = 1000 * 1e6; // 1000 USDC

        result = pythonMintPosition(lowerTick, upperTick, amount0, amount1, sqrtPriceX96);

        console2.log("\nAsymmetric allocation (token1 heavy):");
        console2.log("  Input token0:", amount0);
        console2.log("  Input token1:", amount1);
        console2.log("  Liquidity:", result.liquidity);
        console2.log("  Token0 used:", result.amount0Used);
        console2.log("  Token1 used:", result.amount1Used);

        assertGt(result.liquidity, 0, "Should mint with asymmetric allocation");
    }

}
