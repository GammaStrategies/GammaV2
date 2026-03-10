// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {SharedStructs} from "../base/SharedStructs.sol";
import {WithdrawLogic} from "./WithdrawLogic.sol";
import {DepositRatioLib} from "./DepositRatioLib.sol";
import {PoolManagerUtils} from "./PoolManagerUtils.sol";

/**
 * @title DepositLogic
 * @notice Library containing all deposit-related logic for MultiPositionManager
 */
library DepositLogic {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant PRECISION = 1e36;

    // Custom errors
    error InvalidRecipient();
    error CannotSendETHForERC20Pair();
    error NoSharesMinted();
    error InvalidInMinLength();

    // Events
    event Deposit(address indexed from, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);

    event Compound(uint256 amount0, uint256 amount1);

    /**
     * @notice Process a deposit (tokens go to vault as idle balance)
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param deposit0Desired Desired amount of token0 to deposit
     * @param deposit1Desired Desired amount of token1 to deposit
     * @param to Recipient address for shares
     * @param totalSupply Current total supply of shares
     * @param msgValue Value sent with transaction
     * @return shares Number of shares minted
     * @return deposit0 Actual amount of token0 deposited
     * @return deposit1 Actual amount of token1 deposited
     */
    function processDeposit(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 deposit0Desired,
        uint256 deposit1Desired,
        address to,
        address from,
        uint256 totalSupply,
        uint256 msgValue
    ) external returns (uint256 shares, uint256 deposit0, uint256 deposit1) {
        if (to == address(0)) revert InvalidRecipient();
        if (!s.currency0.isAddressZero() && msgValue != 0) {
            revert CannotSendETHForERC20Pair();
        }

        // Use the actual deposit amounts
        deposit0 = deposit0Desired;
        deposit1 = deposit1Desired;

        if (totalSupply == 0) {
            // First deposit - use simple max since we don't have positions yet
            shares = Math.max(deposit0, deposit1);
        } else {
            // Calculate shares for subsequent deposits
            shares = calculateShares(s, poolManager, deposit0, deposit1, totalSupply);
        }

        if (shares == 0) revert NoSharesMinted();

        // Emit event
        emit Deposit(from, to, deposit0, deposit1, shares);

        // Return values for main contract to handle minting and transfers
        return (shares, deposit0, deposit1);
    }

    /**
     * @notice Calculate shares to mint for a deposit
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param deposit0 Amount of token0 to deposit
     * @param deposit1 Amount of token1 to deposit
     * @param totalSupply Current total supply of shares
     * @return shares Number of shares to mint
     */
    function calculateShares(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 deposit0,
        uint256 deposit1,
        uint256 totalSupply
    ) public view returns (uint256 shares) {
        // Get current pool totals
        (uint256 pool0, uint256 pool1,,) = WithdrawLogic.getTotalAmounts(s, poolManager);

        // Get price from the pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(s.poolKey.toId());

        // Calculate price of token0 in terms of token1 with PRECISION
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        // Calculate deposit value in token1 terms
        uint256 depositValueInToken1 = deposit1 + FullMath.mulDiv(deposit0, price, PRECISION);

        // Calculate pool value in token1 terms
        uint256 pool0PricedInToken1 = FullMath.mulDiv(pool0, price, PRECISION);
        uint256 poolValueInToken1 = pool0PricedInToken1 + pool1;

        // Calculate shares
        if (poolValueInToken1 != 0) {
            shares = FullMath.mulDiv(depositValueInToken1, totalSupply, poolValueInToken1);
        } else {
            shares = depositValueInToken1;
        }
    }

    /**
     * @notice Get amounts for direct deposit into positions
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param deposit0 Amount of token0 being deposited
     * @param deposit1 Amount of token1 being deposited
     * @param inMin Minimum input amounts per position
     * @return amount0ForPositions Amount of token0 for positions
     * @return amount1ForPositions Amount of token1 for positions
     */
    function getDirectDepositAmounts(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 deposit0,
        uint256 deposit1,
        uint256[2][] memory inMin
    ) external view returns (uint256 amount0ForPositions, uint256 amount1ForPositions) {
        if (s.basePositionsLength == 0) {
            return (0, 0);
        }

        // Validate inMin array size (basePositions + actual limit positions count)
        if (inMin.length != s.basePositionsLength + s.limitPositionsLength) revert InvalidInMinLength();

        // Get current totals
        (uint256 total0, uint256 total1,,) = WithdrawLogic.getTotalAmounts(s, poolManager);

        // Use library to calculate amounts that fit the ratio
        return DepositRatioLib.getRatioAmounts(total0, total1, deposit0, deposit1);
    }

    /**
     * @notice Process direct deposit liquidity addition to existing positions
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param inMin Minimum amounts per position for slippage protection
     */
    function directDepositLiquidity(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 amount0,
        uint256 amount1,
        uint256[2][] memory inMin
    ) external {
        // Calculate distribution amounts and add liquidity
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            calculateDirectDepositAmounts(s, poolManager, amount0, amount1);
        addLiquidityToPositions(s, poolManager, amounts0, amounts1, inMin);
    }

    struct DepositAmountsParams {
        IPoolManager poolManager;
        PoolKey poolKey;
        uint256 amount0;
        uint256 amount1;
        uint256 basePositionsLength;
        uint256 limitPositionsLength;
        uint256 totalPositions;
    }

    /**
     * @notice Calculate how to distribute deposit amounts across positions
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param amount0 Amount of token0 to distribute
     * @param amount1 Amount of token1 to distribute
     * @return amounts0 Array of token0 amounts for each position
     * @return amounts1 Array of token1 amounts for each position
     */
    function calculateDirectDepositAmounts(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 amount0,
        uint256 amount1
    ) public view returns (uint256[] memory amounts0, uint256[] memory amounts1) {
        DepositAmountsParams memory params = DepositAmountsParams({
            poolManager: poolManager,
            poolKey: s.poolKey,
            amount0: amount0,
            amount1: amount1,
            basePositionsLength: s.basePositionsLength,
            limitPositionsLength: s.limitPositionsLength,
            totalPositions: s.basePositionsLength + s.limitPositionsLength
        });

        // Get current token amounts in each position
        uint256[] memory positionToken0 = new uint256[](params.totalPositions);
        uint256[] memory positionToken1 = new uint256[](params.totalPositions);
        (uint256 totalToken0InPositions, uint256 totalToken1InPositions) =
            _populatePositionTokens(s, params, positionToken0, positionToken1);

        // If no tokens in positions, fall back to liquidity-based distribution
        if (totalToken0InPositions == 0 && totalToken1InPositions == 0) {
            // Get total liquidity for fallback
            uint256 totalLiquidity = _getTotalLiquidityForFallback(s, params);

            if (totalLiquidity == 0) {
                // No positions to add to
                amounts0 = new uint256[](params.totalPositions);
                amounts1 = new uint256[](params.totalPositions);
                return (amounts0, amounts1);
            }

            // For now, just return empty arrays since we can't distribute without knowing token requirements
            // This case should be rare (positions with liquidity but no tokens)
            amounts0 = new uint256[](params.totalPositions);
            amounts1 = new uint256[](params.totalPositions);
            return (amounts0, amounts1);
        }

        // First determine what CAN actually go into positions based on their ratio
        // Use library function to calculate amounts that maintain the ratio
        (amount0, amount1) = DepositRatioLib.getRatioAmounts(
            totalToken0InPositions, totalToken1InPositions, params.amount0, params.amount1
        );

        // Now distribute these amounts proportionally based on current holdings
        amounts0 = new uint256[](params.totalPositions);
        amounts1 = new uint256[](params.totalPositions);

        // Distribute token0 to positions that hold token0
        if (totalToken0InPositions != 0 && amount0 != 0) {
            for (uint256 i = 0; i < params.totalPositions;) {
                if (positionToken0[i] != 0) {
                    amounts0[i] = FullMath.mulDiv(amount0, positionToken0[i], totalToken0InPositions);
                }
                unchecked {
                    ++i;
                }
            }
        }

        // Distribute token1 to positions that hold token1
        if (totalToken1InPositions != 0 && amount1 != 0) {
            for (uint256 i = 0; i < params.totalPositions;) {
                if (positionToken1[i] != 0) {
                    amounts1[i] = FullMath.mulDiv(amount1, positionToken1[i], totalToken1InPositions);
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _populatePositionTokens(
        SharedStructs.ManagerStorage storage s,
        DepositAmountsParams memory params,
        uint256[] memory positionToken0,
        uint256[] memory positionToken1
    ) private view returns (uint256 totalToken0InPositions, uint256 totalToken1InPositions) {
        // Get token amounts for base positions
        for (uint8 i = 0; i < params.basePositionsLength;) {
            IMultiPositionManager.Range memory range = s.basePositions[i];
            (, uint256 amount0InPos, uint256 amount1InPos,,) =
                PoolManagerUtils.getAmountsOf(params.poolManager, params.poolKey, range);
            positionToken0[i] = amount0InPos;
            positionToken1[i] = amount1InPos;
            unchecked {
                totalToken0InPositions += amount0InPos;
                totalToken1InPositions += amount1InPos;
                ++i;
            }
        }

        // Get token amounts for limit positions if they exist
        uint256 limitIndex;
        for (uint8 i = 0; i < 2;) {
            IMultiPositionManager.Range memory limitRange = s.limitPositions[i];
            if (limitRange.lowerTick != limitRange.upperTick) {
                uint256 idx = params.basePositionsLength + limitIndex;
                (, uint256 amount0InPos, uint256 amount1InPos,,) =
                    PoolManagerUtils.getAmountsOf(params.poolManager, params.poolKey, limitRange);
                positionToken0[idx] = amount0InPos;
                positionToken1[idx] = amount1InPos;
                unchecked {
                    totalToken0InPositions += amount0InPos;
                    totalToken1InPositions += amount1InPos;
                    ++limitIndex;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _getTotalLiquidityForFallback(SharedStructs.ManagerStorage storage s, DepositAmountsParams memory params)
        private
        view
        returns (uint256 totalLiquidity)
    {
        for (uint8 i = 0; i < params.basePositionsLength;) {
            IMultiPositionManager.Range memory range = s.basePositions[i];
            (uint128 liquidity,,,,) = PoolManagerUtils.getAmountsOf(params.poolManager, params.poolKey, range);
            unchecked {
                totalLiquidity += liquidity;
                ++i;
            }
        }

        for (uint8 i = 0; i < 2;) {
            IMultiPositionManager.Range memory limitRange = s.limitPositions[i];
            if (limitRange.lowerTick != limitRange.upperTick) {
                (uint128 liquidity,,,,) = PoolManagerUtils.getAmountsOf(params.poolManager, params.poolKey, limitRange);
                unchecked {
                    totalLiquidity += liquidity;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Add liquidity to positions with calculated amounts
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param amounts0 Array of token0 amounts for each position
     * @param amounts1 Array of token1 amounts for each position
     * @param inMin Minimum amounts per position for slippage protection
     */
    function addLiquidityToPositions(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256[] memory amounts0,
        uint256[] memory amounts1,
        uint256[2][] memory inMin
    ) private {
        // Add liquidity to each base position
        uint256 baseLength = s.basePositionsLength;
        uint256 totalPositions = baseLength + s.limitPositionsLength;

        // If empty inMin passed, create zero-filled array (no slippage protection)
        if (inMin.length == 0) {
            inMin = new uint256[2][](totalPositions);
        }
        for (uint8 i = 0; i < baseLength;) {
            if (amounts0[i] != 0 || amounts1[i] != 0) {
                PoolManagerUtils._mintLiquidityForAmounts(
                    poolManager, s.poolKey, s.basePositions[i], amounts0[i], amounts1[i], inMin[i]
                );
            }
            unchecked {
                ++i;
            }
        }

        // Add liquidity to limit positions if they exist
        uint256 limitIndex;
        for (uint8 i = 0; i < 2;) {
            if (s.limitPositions[i].lowerTick != s.limitPositions[i].upperTick) {
                uint256 idx = baseLength + limitIndex;
                if (amounts0[idx] != 0 || amounts1[idx] != 0) {
                    PoolManagerUtils._mintLiquidityForAmounts(
                        poolManager, s.poolKey, s.limitPositions[i], amounts0[idx], amounts1[idx], inMin[idx]
                    );
                }
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
     * @notice Process compound: collect fees via zeroBurn, add idle to positions
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param inMin Minimum amounts for slippage protection
     */
    function processCompound(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256[2][] memory inMin
    ) external {
        if (s.basePositionsLength == 0) return;

        // Step 1: Collect fees into vault via zeroBurn
        WithdrawLogic.zeroBurnAllWithoutUnlock(s, poolManager);

        // Step 2: Get idle balances (fees + existing idle)
        uint256 idle0 = s.currency0.balanceOfSelf();
        uint256 idle1 = s.currency1.balanceOfSelf();

        if (idle0 == 0 && idle1 == 0) return;

        // Step 3: Add liquidity to positions
        // Calculate distribution amounts and add liquidity
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            calculateDirectDepositAmounts(s, poolManager, idle0, idle1);
        addLiquidityToPositions(s, poolManager, amounts0, amounts1, inMin);

        // Emit compound event
        emit Compound(idle0, idle1);
    }
}
