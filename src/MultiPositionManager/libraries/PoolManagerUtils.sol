// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "./CurrencySettler.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {LiquidityAmountsCapped} from "./LiquidityAmountsCapped.sol";

library PoolManagerUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SignedMath for int256;
    using SafeCast for *;

    bytes32 constant POSITION_ID = bytes32(uint256(1));
    bytes constant HOOK_DATA = "";

    event ZeroBurn(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);

    error SlippageExceeded();
    error InvalidPositionData(IMultiPositionManager.Position position);
    error PoolNotInitialized(PoolKey poolKey);

    uint128 internal constant MAX_LIQUIDITY_DELTA = uint128(type(int128).max);

    function mintLiquidities(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[] memory baseRanges,
        IMultiPositionManager.Range[2] memory limitRanges,
        uint128[] memory liquidities,
        uint256[2][] memory inMin,
        bool useCarpet
    ) external returns (IMultiPositionManager.PositionData[] memory) {
        // Allocate array for all positions (base + max 2 limit positions)
        IMultiPositionManager.PositionData[] memory positionData =
            new IMultiPositionManager.PositionData[](baseRanges.length + 2);
        uint256 positionCount = 0;
        bool useFloorRounding = useCarpet && baseRanges.length > 1;
        int24 minUsable = 0;
        int24 maxUsable = 0;
        if (useFloorRounding) {
            minUsable = TickMath.minUsableTick(poolKey.tickSpacing);
            maxUsable = TickMath.maxUsableTick(poolKey.tickSpacing);
        }

        for (uint8 i = 0; i < baseRanges.length;) {
            positionData[positionCount] = _mintBasePosition(
                poolManager,
                poolKey,
                baseRanges[i],
                liquidities[i],
                inMin[i],
                useFloorRounding,
                minUsable,
                maxUsable
            );
            unchecked {
                ++positionCount;
                ++i;
            }
        }

        // mint limit positions if they are defined (checked inside the function)
        positionCount = _mintLimitPositions(poolManager, poolKey, limitRanges, positionData, positionCount);

        // Resize array to actual count (remove empty slots)
        assembly {
            mstore(positionData, positionCount)
        }

        return positionData;
    }

    function _mintBasePosition(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint128 liquidity,
        uint256[2] memory inMin,
        bool useFloorRounding,
        int24 minUsable,
        int24 maxUsable
    ) private returns (IMultiPositionManager.PositionData memory) {
        (uint256 currencyDelta0, uint256 currencyDelta1) =
            _getCurrencyDeltas(poolManager, poolKey.currency0, poolKey.currency1);
        (uint256 amount0, uint256 amount1) =
            _getAmountsForLiquidityForMint(poolManager, poolKey, range, liquidity, useFloorRounding, minUsable, maxUsable);
        if (amount0 > currencyDelta0) {
            amount0 = currencyDelta0;
        }
        if (amount1 > currencyDelta1) {
            amount1 = currencyDelta1;
        }

        return _mintLiquidityForAmounts(poolManager, poolKey, range, amount0, amount1, inMin);
    }

    // if there's still remaining tokens, create a limit position(single-sided position)
    function _mintLimitPositions(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[2] memory limitRanges,
        IMultiPositionManager.PositionData[] memory positionData,
        uint256 positionCount
    ) internal returns (uint256) {
        if (limitRanges[0].lowerTick != limitRanges[0].upperTick) {
            uint256 currencyDelta1 = _getCurrencyDelta(poolManager, poolKey.currency1);

            if (currencyDelta1 != 0) {
                IMultiPositionManager.PositionData memory data = _mintLiquidityForAmounts(
                    poolManager, poolKey, limitRanges[0], 0, currencyDelta1, [uint256(0), uint256(0)]
                );
                positionData[positionCount] = data;
                unchecked {
                    ++positionCount;
                }
            }
        }

        if (limitRanges[1].lowerTick != limitRanges[1].upperTick) {
            uint256 currencyDelta0 = _getCurrencyDelta(poolManager, poolKey.currency0);

            if (currencyDelta0 != 0) {
                IMultiPositionManager.PositionData memory data = _mintLiquidityForAmounts(
                    poolManager, poolKey, limitRanges[1], currencyDelta0, 0, [uint256(0), uint256(0)]
                );
                positionData[positionCount] = data;
                unchecked {
                    ++positionCount;
                }
            }
        }

        return positionCount;
    }

    function _mintLiquidityForAmounts(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint256 amount0,
        uint256 amount1,
        uint256[2] memory inMin
    ) internal returns (IMultiPositionManager.PositionData memory) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) {
            revert PoolNotInitialized(poolKey);
        }

        if (
            range.lowerTick >= range.upperTick || range.lowerTick % poolKey.tickSpacing != 0
                || range.upperTick % poolKey.tickSpacing != 0
        ) {
            IMultiPositionManager.Position memory pos = IMultiPositionManager.Position({
                poolKey: poolKey,
                lowerTick: range.lowerTick,
                upperTick: range.upperTick
            });
            revert InvalidPositionData(pos);
        }

        uint128 liquidity = LiquidityAmountsCapped.getLiquidityForAmountsCapped(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.lowerTick),
            TickMath.getSqrtPriceAtTick(range.upperTick),
            amount0,
            amount1
        );
        liquidity = _capLiquidityForModify(liquidity);

        uint256 actualAmount0;
        uint256 actualAmount1;

        if (liquidity != 0) {
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: range.lowerTick,
                    tickUpper: range.upperTick,
                    liquidityDelta: liquidity.toInt128(),
                    salt: POSITION_ID
                }),
                HOOK_DATA
            );

            /// callerDelta.amount0() and callerDelta.amount0() are all negative
            actualAmount0 = int256(callerDelta.amount0()).abs();
            actualAmount1 = int256(callerDelta.amount1()).abs();

            if (actualAmount0 < inMin[0] || actualAmount1 < inMin[1]) {
                revert SlippageExceeded();
            }
        }

        return
            IMultiPositionManager.PositionData({liquidity: liquidity, amount0: actualAmount0, amount1: actualAmount1});
    }

    function _capLiquidityForModify(uint128 liquidity) internal pure returns (uint128) {
        if (liquidity > MAX_LIQUIDITY_DELTA) return MAX_LIQUIDITY_DELTA;
        return liquidity;
    }

    function burnLiquidities(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[] memory baseRanges,
        IMultiPositionManager.Range[2] memory limitRanges,
        uint256 shares,
        uint256 totalSupply,
        uint256[2][] memory outMin
    ) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) return (amount0, amount1);

        uint256 baseRangesLength = baseRanges.length;
        uint256 amountOut0;
        uint256 amountOut1;

        // Burn base positions
        for (uint8 i = 0; i < baseRangesLength;) {
            (amountOut0, amountOut1) =
                burnLiquidityForShare(poolManager, poolKey, baseRanges[i], shares, totalSupply, outMin[i]);

            unchecked {
                amount0 = amount0 + amountOut0;
                amount1 = amount1 + amountOut1;
                ++i;
            }
        }

        // Burn limit positions with their specific outMin
        (amountOut0, amountOut1) =
            _burnLimitPositions(poolManager, poolKey, limitRanges, shares, totalSupply, outMin, baseRangesLength);
        unchecked {
            amount0 = amount0 + amountOut0;
            amount1 = amount1 + amountOut1;
        }
    }

    function _burnLimitPositions(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[2] memory limitRanges,
        uint256 shares,
        uint256 totalSupply,
        uint256[2][] memory outMin,
        uint256 baseRangesLength
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) return (0, 0);

        uint256 limitIndex = 0;
        for (uint8 i = 0; i < 2;) {
            // Skip empty limit positions
            if (limitRanges[i].lowerTick != limitRanges[i].upperTick) {
                uint256 outMinIndex = baseRangesLength + limitIndex;
                // Use provided outMin if available, otherwise use [0, 0] for backward compatibility
                uint256[2] memory positionOutMin =
                    outMinIndex < outMin.length ? outMin[outMinIndex] : [uint256(0), uint256(0)];

                (uint256 amountOut0, uint256 amountOut1) =
                    burnLiquidityForShare(poolManager, poolKey, limitRanges[i], shares, totalSupply, positionOutMin);

                unchecked {
                    amount0 = amount0 + amountOut0;
                    amount1 = amount1 + amountOut1;
                    ++limitIndex;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function burnLiquidityForShare(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint256 shares,
        uint256 totalSupply,
        uint256[2] memory outMin
    ) public returns (uint256 amountOut0, uint256 amountOut1) {
        if (range.lowerTick == range.upperTick) {
            return (0, 0);
        }
        (uint128 liquidity,,) =
            poolManager.getPositionInfo(poolKey.toId(), address(this), range.lowerTick, range.upperTick, POSITION_ID);

        uint256 liquidityForShares = FullMath.mulDiv(liquidity, shares, totalSupply);

        if (liquidityForShares != 0) {
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: range.lowerTick,
                    tickUpper: range.upperTick,
                    liquidityDelta: -(liquidityForShares).toInt128(),
                    salt: POSITION_ID
                }),
                HOOK_DATA
            );

            // when withdrawing liquidity or collecting fee (collecting fee is same as withdrawing liquidity 0 ),
            // callerDelta is always positive
            // when adding liquidity, most of time callerDelta is negative but could be positive
            //  when fee is larger than liquidity itself (but fee already settled in `zeroBurn`)
            // Slippage checks should only apply to principal (exclude accrued fees).
            BalanceDelta principalDelta = callerDelta - feesAccrued;
            uint256 principalOut0 = principalDelta.amount0().toUint128();
            uint256 principalOut1 = principalDelta.amount1().toUint128();

            amountOut0 = callerDelta.amount0().toUint128();
            amountOut1 = callerDelta.amount1().toUint128();

            if (principalOut0 < outMin[0] || principalOut1 < outMin[1]) {
                revert SlippageExceeded();
            }
        }
    }

    function zeroBurnAll(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[] memory baseRanges,
        IMultiPositionManager.Range[2] memory limitRanges,
        Currency currency0,
        Currency currency1,
        uint16 fee
    ) external returns (uint256 totalFee0, uint256 totalFee1) {
        uint256 baseRangesLength = baseRanges.length;
        uint256 fee0;
        uint256 fee1;
        for (uint8 i = 0; i < baseRangesLength;) {
            (fee0, fee1) = _zeroBurnWithoutUnlock(poolManager, poolKey, baseRanges[i]);
            unchecked {
                totalFee0 = totalFee0 + fee0;
                totalFee1 = totalFee1 + fee1;
                ++i;
            }
        }

        (fee0, fee1) = _zeroBurnWithoutUnlock(poolManager, poolKey, limitRanges[0]);
        unchecked {
            totalFee0 = totalFee0 + fee0;
            totalFee1 = totalFee1 + fee1;
        }
        (fee0, fee1) = _zeroBurnWithoutUnlock(poolManager, poolKey, limitRanges[1]);
        unchecked {
            totalFee0 = totalFee0 + fee0;
            totalFee1 = totalFee1 + fee1;
        }

        // Calculate fees by dividing by fee denominator
        uint256 treasuryFee0 = totalFee0 / fee;
        uint256 treasuryFee1 = totalFee1 / fee;

        if (treasuryFee0 != 0) {
            poolManager.mint(address(this), uint256(uint160(Currency.unwrap(currency0))), treasuryFee0);
        }
        if (treasuryFee1 != 0) {
            poolManager.mint(address(this), uint256(uint160(Currency.unwrap(currency1))), treasuryFee1);
        }
    }

    function getTotalFeesOwed(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[] memory baseRanges,
        IMultiPositionManager.Range[2] memory limitRanges
    ) internal view returns (uint256 totalFee0, uint256 totalFee1) {
        uint256 baseRangesLength = baseRanges.length;
        for (uint8 i = 0; i < baseRangesLength;) {
            if (baseRanges[i].lowerTick != baseRanges[i].upperTick) {
                (uint256 fee0, uint256 fee1) = _getFeesOwed(poolManager, poolKey, baseRanges[i]);
                unchecked {
                    totalFee0 = totalFee0 + fee0;
                    totalFee1 = totalFee1 + fee1;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (limitRanges[0].lowerTick != limitRanges[0].upperTick) {
            (uint256 fee0, uint256 fee1) = _getFeesOwed(poolManager, poolKey, limitRanges[0]);
            unchecked {
                totalFee0 = totalFee0 + fee0;
                totalFee1 = totalFee1 + fee1;
            }
        }
        if (limitRanges[1].lowerTick != limitRanges[1].upperTick) {
            (uint256 fee0, uint256 fee1) = _getFeesOwed(poolManager, poolKey, limitRanges[1]);
            unchecked {
                totalFee0 = totalFee0 + fee0;
                totalFee1 = totalFee1 + fee1;
            }
        }
    }

    function _zeroBurnWithoutUnlock(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range
    ) internal returns (uint256 fee0, uint256 fee1) {
        if (range.lowerTick == range.upperTick) {
            return (0, 0);
        }
        (uint128 liquidity,,) =
            poolManager.getPositionInfo(poolKey.toId(), address(this), range.lowerTick, range.upperTick, POSITION_ID);

        if (liquidity != 0) {
            // Check fees first
            (uint256 feesOwed0, uint256 feesOwed1) = _getFeesOwed(poolManager, poolKey, range);
            // Only proceed with modifyLiquidity if either fee is non-zero
            if (feesOwed0 != 0 || feesOwed1 != 0) {
                (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                    poolKey,
                    ModifyLiquidityParams({
                        tickLower: range.lowerTick,
                        tickUpper: range.upperTick,
                        liquidityDelta: 0,
                        salt: POSITION_ID
                    }),
                    HOOK_DATA
                );

                fee0 = uint128(feesAccrued.amount0());
                fee1 = uint128(feesAccrued.amount1());
                emit ZeroBurn(range.lowerTick, range.upperTick, fee0, fee1);
            }
        }
    }

    function close(IPoolManager poolManager, Currency currency) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta == 0) {
            return;
        } else if (currencyDelta < 0) {
            currency.settle(poolManager, address(this), uint256(-currencyDelta), false);
        } else {
            currency.take(poolManager, address(this), uint256(currencyDelta), false);
        }
    }

    function _getCurrencyDelta(IPoolManager poolManager, Currency currency) internal view returns (uint256 delta) {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        if (currencyDelta > 0) {
            delta = currency.balanceOfSelf() + uint256(currencyDelta);
        } else {
            delta = currency.balanceOfSelf() - uint256(-currencyDelta);
        }

        return delta;
    }

    function _getCurrencyDeltas(IPoolManager poolManager, Currency currency0, Currency currency1)
        internal
        view
        returns (uint256 delta0, uint256 delta1)
    {
        int256 currencyDelta0 = poolManager.currencyDelta(address(this), currency0);
        int256 currencyDelta1 = poolManager.currencyDelta(address(this), currency1);

        if (currencyDelta0 > 0) {
            delta0 = currency0.balanceOfSelf() + uint256(currencyDelta0);
        } else {
            delta0 = currency0.balanceOfSelf() - uint256(-currencyDelta0);
        }
        if (currencyDelta1 > 0) {
            delta1 = currency1.balanceOfSelf() + uint256(currencyDelta1);
        } else {
            delta1 = currency1.balanceOfSelf() - uint256(-currencyDelta1);
        }

        return (delta0, delta1);
    }

    function getAmountsForLiquidity(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint128 liquidity
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.lowerTick),
            TickMath.getSqrtPriceAtTick(range.upperTick),
            liquidity
        );
    }

    function _getAmountsForLiquidityForMint(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint128 liquidity,
        bool useFloorRounding,
        int24 minUsable,
        int24 maxUsable
    ) private view returns (uint256 amount0, uint256 amount1) {
        if (useFloorRounding && (range.lowerTick == minUsable || range.upperTick == maxUsable)) {
            return _getAmountsForLiquidityRoundedUp(poolManager, poolKey, range, liquidity);
        }
        return getAmountsForLiquidity(poolManager, poolKey, range, liquidity);
    }

    function _getAmountsForLiquidityRoundedUp(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range memory range,
        uint128 liquidity
    ) private view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(range.lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(range.upperTick);

        if (sqrtPriceX96 <= sqrtPriceLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        } else if (sqrtPriceX96 < sqrtPriceUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLower, sqrtPriceUpper, liquidity, true);
        }
    }

    function getAmountsOf(IPoolManager poolManager, PoolKey memory poolKey, IMultiPositionManager.Range memory range)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 feesOwed0, uint256 feesOwed1)
    {
        if (range.lowerTick == range.upperTick) {
            return (0, 0, 0, 0, 0);
        }
        PoolId poolId = poolKey.toId();
        (liquidity,,) =
            poolManager.getPositionInfo(poolId, address(this), range.lowerTick, range.upperTick, POSITION_ID);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(range.lowerTick),
            TickMath.getSqrtPriceAtTick(range.upperTick),
            liquidity
        );

        (feesOwed0, feesOwed1) = _getFeesOwed(poolManager, poolKey, range);
    }

    function _getFeesOwed(IPoolManager poolManager, PoolKey memory poolKey, IMultiPositionManager.Range memory range)
        internal
        view
        returns (uint256 feesOwed0, uint256 feesOwed1)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolKey.toId(), range.lowerTick, range.upperTick);

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            poolManager.getPositionInfo(poolKey.toId(), address(this), range.lowerTick, range.upperTick, POSITION_ID);

        unchecked {
            feesOwed0 = FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 = FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @notice Calculate outMin for rebalance with slippage protection
     * @param poolManager The pool manager
     * @param poolKey The pool key
     * @param ranges Array of position ranges
     * @param positionData Array of position data (liquidity values)
     * @param maxSlippage Maximum slippage in basis points (10000 = 100%)
     * @return outMin Array of minimum amounts [token0, token1] for each position
     */
    function calculateOutMinForRebalance(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        IMultiPositionManager.Range[] memory ranges,
        IMultiPositionManager.PositionData[] memory positionData,
        uint256 maxSlippage
    ) internal view returns (uint256[2][] memory outMin) {
        uint256 totalPositionsLength = ranges.length;

        if (totalPositionsLength == 0) {
            return outMin;
        }

        outMin = new uint256[2][](totalPositionsLength);
        uint256 slippageMultiplier = 10000 - maxSlippage;

        for (uint256 i = 0; i < totalPositionsLength;) {
            (uint256 amount0, uint256 amount1) =
                getAmountsForLiquidity(poolManager, poolKey, ranges[i], uint128(positionData[i].liquidity));

            unchecked {
                outMin[i] = [amount0 * slippageMultiplier / 10000, amount1 * slippageMultiplier / 10000];
                ++i;
            }
        }

        return outMin;
    }
}
