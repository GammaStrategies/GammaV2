// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {SharedStructs} from "../base/SharedStructs.sol";
import {PoolManagerUtils} from "./PoolManagerUtils.sol";
import {WithdrawLogic} from "./WithdrawLogic.sol";

/**
 * @title PositionLogic
 * @notice Library containing position management logic for MultiPositionManager
 */
library PositionLogic {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Constants
    uint256 constant PRECISION = 1e36;
    uint256 constant RATIO_PRECISION = 1e18;

    // Structs
    struct Ratios {
        uint256 pool0Ratio;
        uint256 pool1Ratio;
        uint256 total0Ratio;
        uint256 total1Ratio;
        uint256 inPositionRatio;
        uint256 outOfPositionRatio;
        uint256 baseRatio;
        uint256 limitRatio;
        uint256 base0Ratio;
        uint256 base1Ratio;
        uint256 limit0Ratio;
        uint256 limit1Ratio;
    }

    // Custom errors
    error DuplicatedRange(IMultiPositionManager.Range range);

    /**
     * @notice Set limit ranges based on limit width and base ranges
     * @param s Storage struct
     * @param limitWidth Width of limit positions
     * @param baseRanges Base position ranges
     * @param tickSpacing Tick spacing of the pool
     * @param currentTick Current tick of the pool
     */
    function setLimitRanges(
        SharedStructs.ManagerStorage storage s,
        uint24 limitWidth,
        IMultiPositionManager.Range[] memory baseRanges,
        int24 tickSpacing,
        int24 currentTick
    ) external {
        if (limitWidth == 0) {
            delete s.limitPositions;
            s.limitPositionsLength = 0;
            return;
        }

        if (int24(limitWidth) % tickSpacing != 0) {
            // increase `limitWidth` to round up multiple of tickSpacing
            limitWidth = uint24((int24(limitWidth) / tickSpacing + 1) * tickSpacing);
        }

        // Check against NEW base ranges (not historical ones)
        // Use do-while to handle consecutive width collisions
        uint256 baseRangesLength = baseRanges.length;
        bool collision;
        do {
            collision = false;
            for (uint256 i = 0; i < baseRangesLength;) {
                int24 rangeWidth = baseRanges[i].upperTick - baseRanges[i].lowerTick;
                if (rangeWidth == int24(limitWidth)) {
                    limitWidth = uint24(int24(limitWidth) + tickSpacing);
                    collision = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        } while (collision);

        int24 baseTick;
        if (currentTick % tickSpacing == 0) {
            baseTick = currentTick;
        } else if (currentTick % tickSpacing > 0) {
            baseTick = (currentTick / tickSpacing) * tickSpacing;
        } else {
            baseTick = (currentTick / tickSpacing - 1) * tickSpacing;
        }

        (s.limitPositions[0].lowerTick, s.limitPositions[0].upperTick) =
            roundUp(baseTick - int24(limitWidth), baseTick, tickSpacing);
        (s.limitPositions[1].lowerTick, s.limitPositions[1].upperTick) =
            roundUp(baseTick + tickSpacing, baseTick + tickSpacing + int24(limitWidth), tickSpacing);

        // Update limitPositionsLength based on non-empty positions
        s.limitPositionsLength = 0;
        if (s.limitPositions[0].lowerTick != s.limitPositions[0].upperTick) {
            unchecked {
                ++s.limitPositionsLength;
            }
        }
        if (s.limitPositions[1].lowerTick != s.limitPositions[1].upperTick) {
            unchecked {
                ++s.limitPositionsLength;
            }
        }
    }

    /**
     * @notice Calculate limit ranges without modifying storage (for SimpleLens preview)
     * @param limitWidth Width of limit positions
     * @param baseRanges Base position ranges
     * @param tickSpacing Tick spacing of the pool
     * @param currentTick Current tick of the pool
     * @return lowerLimit Lower limit range
     * @return upperLimit Upper limit range
     */
    function calculateLimitRanges(
        uint24 limitWidth,
        IMultiPositionManager.Range[] memory baseRanges,
        int24 tickSpacing,
        int24 currentTick
    )
        public
        pure
        returns (IMultiPositionManager.Range memory lowerLimit, IMultiPositionManager.Range memory upperLimit)
    {
        if (limitWidth == 0) {
            return (
                IMultiPositionManager.Range({lowerTick: 0, upperTick: 0}),
                IMultiPositionManager.Range({lowerTick: 0, upperTick: 0})
            );
        }

        if (int24(limitWidth) % tickSpacing != 0) {
            // increase `limitWidth` to round up multiple of tickSpacing
            limitWidth = uint24((int24(limitWidth) / tickSpacing + 1) * tickSpacing);
        }

        // Check against NEW base ranges (not historical ones)
        // Use do-while to handle consecutive width collisions
        uint256 baseRangesLength = baseRanges.length;
        bool collision;
        do {
            collision = false;
            for (uint256 i = 0; i < baseRangesLength;) {
                int24 rangeWidth = baseRanges[i].upperTick - baseRanges[i].lowerTick;
                if (rangeWidth == int24(limitWidth)) {
                    limitWidth = uint24(int24(limitWidth) + tickSpacing);
                    collision = true;
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        } while (collision);

        int24 baseTick;
        if (currentTick % tickSpacing == 0) {
            baseTick = currentTick;
        } else if (currentTick % tickSpacing > 0) {
            baseTick = (currentTick / tickSpacing) * tickSpacing;
        } else {
            baseTick = (currentTick / tickSpacing - 1) * tickSpacing;
        }

        (lowerLimit.lowerTick, lowerLimit.upperTick) = roundUp(baseTick - int24(limitWidth), baseTick, tickSpacing);
        (upperLimit.lowerTick, upperLimit.upperTick) =
            roundUp(baseTick + tickSpacing, baseTick + tickSpacing + int24(limitWidth), tickSpacing);
    }

    /**
     * @notice Round up tick values to valid range
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param tickSpacing Tick spacing of the pool
     * @return Rounded lower and upper ticks
     */
    function roundUp(int24 tickLower, int24 tickUpper, int24 tickSpacing) public pure returns (int24, int24) {
        // Get min/max usable ticks that are aligned with tick spacing
        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        // Ensure lower tick is at least the min usable tick
        if (tickLower < minUsableTick) {
            tickLower = minUsableTick;
        }
        // Ensure upper tick is at most the max usable tick
        if (tickUpper > maxUsableTick) {
            tickUpper = maxUsableTick;
        }
        // Handle invalid ranges
        if (tickLower >= tickUpper) {
            return (0, 0);
        }

        return (tickLower, tickUpper);
    }

    /**
     * @notice Check for duplicate ranges
     * @param allRanges All ranges to check
     */
    function checkRanges(IMultiPositionManager.Range[] memory allRanges) external pure {
        uint256 rangesLength = allRanges.length;
        for (uint256 i = 0; i < rangesLength;) {
            for (uint256 j = i + 1; j < rangesLength;) {
                // Skip empty ranges
                if (allRanges[j].lowerTick == allRanges[j].upperTick) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                if (
                    allRanges[i].lowerTick == allRanges[j].lowerTick && allRanges[i].upperTick == allRanges[j].upperTick
                ) {
                    revert DuplicatedRange(allRanges[j]);
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get base positions as array
     * @param s Storage struct
     * @return ranges Array of base positions
     */
    function getBasePositionsArray(SharedStructs.ManagerStorage storage s)
        public
        view
        returns (IMultiPositionManager.Range[] memory ranges)
    {
        uint256 baseLength = s.basePositionsLength;
        ranges = new IMultiPositionManager.Range[](baseLength);
        for (uint8 i = 0; i < baseLength;) {
            ranges[i] = s.basePositions[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get limit positions as array
     * @param s Storage struct
     * @return ranges Array of limit positions (always size 2)
     */
    function getLimitPositionsArray(SharedStructs.ManagerStorage storage s)
        public
        view
        returns (IMultiPositionManager.Range[2] memory ranges)
    {
        ranges[0] = s.limitPositions[0];
        ranges[1] = s.limitPositions[1];
    }

    /**
     * @notice Mint liquidity to positions
     * @param poolManager Pool manager contract
     * @param s Storage struct
     * @param liquidities Liquidity amounts for each position
     * @param inMin Minimum input amounts per position
     */
    function mintLiquidities(
        IPoolManager poolManager,
        SharedStructs.ManagerStorage storage s,
        uint128[] memory liquidities,
        uint256[2][] memory inMin,
        bool useCarpet
    ) external returns (IMultiPositionManager.PositionData[] memory) {
        IMultiPositionManager.Range[] memory baseRangesArray = getBasePositionsArray(s);
        IMultiPositionManager.Range[2] memory limitRangesArray = getLimitPositionsArray(s);

        return PoolManagerUtils.mintLiquidities(
            poolManager, s.poolKey, baseRangesArray, limitRangesArray, liquidities, inMin, useCarpet
        );
    }

    /**
     * @notice Burn liquidity from positions
     * @param poolManager Pool manager contract
     * @param s Storage struct
     * @param shares Number of shares to burn
     * @param totalSupply Total supply of shares
     * @param outMin Minimum output amounts per position
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function burnLiquidities(
        IPoolManager poolManager,
        SharedStructs.ManagerStorage storage s,
        uint256 shares,
        uint256 totalSupply,
        uint256[2][] memory outMin
    ) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) return (amount0, amount1);

        IMultiPositionManager.Range[] memory baseRangesArray = getBasePositionsArray(s);
        IMultiPositionManager.Range[2] memory limitRangesArray = getLimitPositionsArray(s);

        (amount0, amount1) = PoolManagerUtils.burnLiquidities(
            poolManager, s.poolKey, baseRangesArray, limitRangesArray, shares, totalSupply, outMin
        );
    }

    /**
     * @notice Get base positions with their data
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @return ranges Array of base position ranges
     * @return positionData Array of position data for each base position
     */
    function getBasePositions(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        external
        view
        returns (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData)
    {
        ranges = new IMultiPositionManager.Range[](s.basePositionsLength);
        positionData = new IMultiPositionManager.PositionData[](s.basePositionsLength);

        for (uint8 i = 0; i < s.basePositionsLength;) {
            ranges[i] = s.basePositions[i];

            (uint128 liquidity, uint256 amount0, uint256 amount1,,) =
                PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, ranges[i]);

            positionData[i] =
                IMultiPositionManager.PositionData({liquidity: liquidity, amount0: amount0, amount1: amount1});

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get all positions (base + non-empty limit) with their data
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @return ranges Array of all position ranges
     * @return positionData Array of position data for each position
     */
    function getPositions(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        external
        view
        returns (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData)
    {
        // Count non-empty limit positions
        uint8 nonEmptyLimitPositions = 0;
        if (s.limitPositions[0].lowerTick != s.limitPositions[0].upperTick) {
            unchecked {
                ++nonEmptyLimitPositions;
            }
        }
        if (s.limitPositions[1].lowerTick != s.limitPositions[1].upperTick) {
            unchecked {
                ++nonEmptyLimitPositions;
            }
        }

        ranges = new IMultiPositionManager.Range[](s.basePositionsLength + nonEmptyLimitPositions);
        positionData = new IMultiPositionManager.PositionData[](s.basePositionsLength + nonEmptyLimitPositions);

        // Include base positions
        for (uint8 i = 0; i < s.basePositionsLength;) {
            ranges[i] = s.basePositions[i];

            (uint128 liquidity, uint256 amount0, uint256 amount1,,) =
                PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, ranges[i]);

            positionData[i] =
                IMultiPositionManager.PositionData({liquidity: liquidity, amount0: amount0, amount1: amount1});

            unchecked {
                ++i;
            }
        }

        // Include limit positions only if they are non-empty
        uint8 limitIndex = 0;
        for (uint8 i = 0; i < 2;) {
            if (s.limitPositions[i].lowerTick != s.limitPositions[i].upperTick) {
                ranges[s.basePositionsLength + limitIndex] = s.limitPositions[i];

                (uint128 liquidity, uint256 amount0, uint256 amount1,,) =
                    PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, ranges[s.basePositionsLength + limitIndex]);

                positionData[s.basePositionsLength + limitIndex] =
                    IMultiPositionManager.PositionData({liquidity: liquidity, amount0: amount0, amount1: amount1});

                unchecked {
                    ++limitIndex;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculate token ratios given amounts and price
     * @dev Converts token0 to token1 terms and calculates distribution ratios
     * @param token0Amount Amount of token0
     * @param token1Amount Amount of token1
     * @param sqrtPriceX96 Square root price in Q96 format
     * @return token0Ratio Ratio of token0 value (1e18 = 100%)
     * @return token1Ratio Ratio of token1 value (1e18 = 100%)
     */
    function _getTokenRatios(uint256 token0Amount, uint256 token1Amount, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 token0Ratio, uint256 token1Ratio)
    {
        // Handle edge case: no tokens
        if (token0Amount == 0 && token1Amount == 0) {
            return (0, 0);
        }

        // Calculate price of token0 in terms of token1 with PRECISION
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        // Convert token0 to token1 terms
        uint256 token0InToken1 = FullMath.mulDiv(token0Amount, price, PRECISION);
        uint256 totalValueInToken1 = token0InToken1 + token1Amount;

        // Calculate ratios (1e18 precision)
        token1Ratio = FullMath.mulDiv(token1Amount, RATIO_PRECISION, totalValueInToken1);
        token0Ratio = RATIO_PRECISION - token1Ratio;
    }

    /**
     * @notice Sum base position amounts
     */
    function _sumBasePositions(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        internal
        view
        returns (uint256 base0, uint256 base1)
    {
        uint256 baseLength = s.basePositionsLength;
        for (uint8 i = 0; i < baseLength;) {
            if (s.basePositions[i].lowerTick != s.basePositions[i].upperTick) {
                (, uint256 amt0, uint256 amt1,,) =
                    PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, s.basePositions[i]);
                unchecked {
                    base0 += amt0;
                    base1 += amt1;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sum limit position amounts
     */
    function _sumLimitPositions(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        internal
        view
        returns (uint256 limit0, uint256 limit1)
    {
        for (uint8 i = 0; i < 2;) {
            if (s.limitPositions[i].lowerTick != s.limitPositions[i].upperTick) {
                (, uint256 amt0, uint256 amt1,,) =
                    PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, s.limitPositions[i]);
                unchecked {
                    limit0 += amt0;
                    limit1 += amt1;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculate in-position and base/limit ratios
     */
    function _calculateDeploymentRatios(
        uint256 total0,
        uint256 total1,
        uint256 position0,
        uint256 position1,
        uint256 base0,
        uint256 base1,
        uint160 sqrtPriceX96
    )
        internal
        pure
        returns (uint256 inPositionRatio, uint256 outOfPositionRatio, uint256 baseRatio, uint256 limitRatio)
    {
        // In-position ratios
        if (total0 == 0 && total1 == 0) {
            inPositionRatio = 0;
            outOfPositionRatio = 0;
        } else {
            uint256 price = FullMath.mulDiv(
                FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96
            );
            uint256 totalVal = FullMath.mulDiv(total0, price, PRECISION) + total1;
            uint256 posVal = FullMath.mulDiv(position0, price, PRECISION) + position1;
            inPositionRatio = FullMath.mulDiv(posVal, RATIO_PRECISION, totalVal);
            outOfPositionRatio = RATIO_PRECISION - inPositionRatio;
        }

        // Base/limit ratios
        if (position0 == 0 && position1 == 0) {
            baseRatio = 0;
            limitRatio = 0;
        } else {
            uint256 price = FullMath.mulDiv(
                FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96
            );
            uint256 baseVal = FullMath.mulDiv(base0, price, PRECISION) + base1;
            uint256 posVal = FullMath.mulDiv(position0, price, PRECISION) + position1;
            baseRatio = FullMath.mulDiv(baseVal, RATIO_PRECISION, posVal);
            limitRatio = RATIO_PRECISION - baseRatio;
        }
    }

    /**
     * @notice Get total portfolio value denominated in each token
     * @dev Converts entire portfolio value to both token0 and token1 terms
     * @param s Storage struct
     * @param poolManager The pool manager instance
     * @return totalValueInToken0 Total value in token0 terms
     * @return totalValueInToken1 Total value in token1 terms
     */
    function getTotalValuesInOneToken(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        external
        view
        returns (uint256 totalValueInToken0, uint256 totalValueInToken1)
    {
        // Get current price
        uint160 sqrtPriceX96;
        (sqrtPriceX96,,,) = poolManager.getSlot0(s.poolKey.toId());

        // Get total amounts (positions + fees + idle)
        uint256 total0;
        uint256 total1;
        (total0, total1,,) = WithdrawLogic.getTotalAmounts(s, poolManager);

        // Handle edge case: no tokens
        if (total0 == 0 && total1 == 0) {
            return (0, 0);
        }

        // Calculate price of token0 in terms of token1 with PRECISION
        // price = (sqrtPriceX96)² / 2^192
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        // Convert token0 to token1 terms
        uint256 token0InToken1 = FullMath.mulDiv(total0, price, PRECISION);
        totalValueInToken1 = token0InToken1 + total1;

        // Convert token1 to token0 terms
        // token1InToken0 = token1 / price = token1 * PRECISION / price
        uint256 token1InToken0 = FullMath.mulDiv(total1, PRECISION, price);
        totalValueInToken0 = total0 + token1InToken0;
    }

    /**
     * @notice Get comprehensive ratios for token distribution and position deployment
     * @dev Returns 8 ratios that provide complete picture of vault state
     * @param s Storage struct
     * @param poolManager The pool manager instance
     * @return ratios Struct containing all ratio values (1e18 = 100%)
     */
    function getRatios(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        external
        view
        returns (Ratios memory ratios)
    {
        uint160 sqrtPriceX96;
        (sqrtPriceX96,,,) = poolManager.getSlot0(s.poolKey.toId());

        // Get all amounts once (avoid duplicate calls)
        uint256 total0;
        uint256 total1;
        (total0, total1,,) = WithdrawLogic.getTotalAmounts(s, poolManager);

        uint256 base0;
        uint256 base1;
        (base0, base1) = _sumBasePositions(s, poolManager);

        uint256 limit0;
        uint256 limit1;
        (limit0, limit1) = _sumLimitPositions(s, poolManager);

        uint256 position0;
        uint256 position1;
        unchecked {
            position0 = base0 + limit0;
            position1 = base1 + limit1;
        }

        // Calculate all token ratios
        (ratios.pool0Ratio, ratios.pool1Ratio) = _getTokenRatios(position0, position1, sqrtPriceX96);
        (ratios.total0Ratio, ratios.total1Ratio) = _getTokenRatios(total0, total1, sqrtPriceX96);
        (ratios.base0Ratio, ratios.base1Ratio) = _getTokenRatios(base0, base1, sqrtPriceX96);
        (ratios.limit0Ratio, ratios.limit1Ratio) = _getTokenRatios(limit0, limit1, sqrtPriceX96);

        // Calculate deployment ratios in scoped block
        {
            // In-position ratios
            if (total0 == 0 && total1 == 0) {
                ratios.inPositionRatio = 0;
                ratios.outOfPositionRatio = 0;
            } else {
                uint256 price = FullMath.mulDiv(
                    FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96
                );
                uint256 totalVal = FullMath.mulDiv(total0, price, PRECISION) + total1;
                uint256 posVal = FullMath.mulDiv(position0, price, PRECISION) + position1;
                ratios.inPositionRatio = FullMath.mulDiv(posVal, RATIO_PRECISION, totalVal);
                ratios.outOfPositionRatio = RATIO_PRECISION - ratios.inPositionRatio;
            }

            // Base/limit ratios
            if (position0 == 0 && position1 == 0) {
                ratios.baseRatio = 0;
                ratios.limitRatio = 0;
            } else {
                uint256 price = FullMath.mulDiv(
                    FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96
                );
                uint256 baseVal = FullMath.mulDiv(base0, price, PRECISION) + base1;
                uint256 posVal = FullMath.mulDiv(position0, price, PRECISION) + position1;
                ratios.baseRatio = FullMath.mulDiv(baseVal, RATIO_PRECISION, posVal);
                ratios.limitRatio = RATIO_PRECISION - ratios.baseRatio;
            }
        }
    }
}
