// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManagerUtils} from "./PoolManagerUtils.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DepositRatioLib
 * @notice Internal library for calculating deposit ratios and proportional distributions
 */
library DepositRatioLib {
    /**
     * @notice Calculate amounts that match the vault's current ratio for directDeposit
     * @param total0 Current total amount of token0 in vault
     * @param total1 Current total amount of token1 in vault
     * @param amount0Desired Amount of token0 user wants to deposit
     * @param amount1Desired Amount of token1 user wants to deposit
     * @return amount0ForPositions Amount of token0 that fits the ratio
     * @return amount1ForPositions Amount of token1 that fits the ratio
     */
    function getRatioAmounts(uint256 total0, uint256 total1, uint256 amount0Desired, uint256 amount1Desired)
        internal
        pure
        returns (uint256 amount0ForPositions, uint256 amount1ForPositions)
    {
        if (total0 == 0 && total1 == 0) {
            // No existing positions, can use full amounts
            return (amount0Desired, amount1Desired);
        }

        if (total0 == 0) {
            // Only token1 in positions
            return (0, amount1Desired);
        }

        if (total1 == 0) {
            // Only token0 in positions
            return (amount0Desired, 0);
        }

        // Calculate amounts that fit the current ratio using cross-product
        uint256 cross = Math.min(amount0Desired * total1, amount1Desired * total0);

        if (cross == 0) {
            return (0, 0);
        }

        // Calculate the amounts that maintain the ratio
        amount0ForPositions = (cross - 1) / total1 + 1;
        amount1ForPositions = (cross - 1) / total0 + 1;

        // Ensure we don't try to use more than deposited
        amount0ForPositions = Math.min(amount0ForPositions, amount0Desired);
        amount1ForPositions = Math.min(amount1ForPositions, amount1Desired);

        return (amount0ForPositions, amount1ForPositions);
    }

    /**
     * @notice Calculate how to distribute amounts across positions proportionally based on liquidity
     * @param positionLiquidities Array of liquidities for each position
     * @param totalLiquidity Total liquidity across all positions
     * @param amount0 Total amount of token0 to distribute
     * @param amount1 Total amount of token1 to distribute
     * @return amounts0 Array of token0 amounts for each position
     * @return amounts1 Array of token1 amounts for each position
     */
    function getProportionalAmounts(
        uint128[] memory positionLiquidities,
        uint256 totalLiquidity,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256[] memory amounts0, uint256[] memory amounts1) {
        uint256 length = positionLiquidities.length;
        amounts0 = new uint256[](length);
        amounts1 = new uint256[](length);

        if (totalLiquidity == 0) {
            return (amounts0, amounts1);
        }

        // Distribute amounts proportionally
        for (uint256 i = 0; i < length; i++) {
            if (positionLiquidities[i] > 0) {
                amounts0[i] = FullMath.mulDiv(amount0, positionLiquidities[i], totalLiquidity);
                amounts1[i] = FullMath.mulDiv(amount1, positionLiquidities[i], totalLiquidity);
            }
        }

        return (amounts0, amounts1);
    }
}
