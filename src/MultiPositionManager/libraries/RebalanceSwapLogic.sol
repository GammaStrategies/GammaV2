// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "../interfaces/IMultiPositionFactory.sol";
import {ILiquidityStrategy} from "../strategies/ILiquidityStrategy.sol";
import {SharedStructs} from "../base/SharedStructs.sol";
import {RebalanceLogic} from "./RebalanceLogic.sol";

/**
 * @title RebalanceSwapLogic
 * @notice Swap execution and swap-based rebalance helpers split from RebalanceLogic to reduce byte size.
 */
library RebalanceSwapLogic {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    error InvalidAggregator();
    error InsufficientTokensForSwap();
    error InsufficientOutput();
    error NoStrategySpecified();

    event SwapExecuted(address indexed aggregator, uint256 amountIn, uint256 amountOut, bool swapToken0);

    /**
     * @notice Execute swap and calculate rebalance ranges in one call
     * @dev Combines swap execution and range calculation for cleaner flow
     * @param s Storage struct
     * @param poolManager The pool manager
     * @param params Rebalance parameters including swap details
     * @return baseRanges The base ranges to rebalance to
     * @return liquidities The liquidity amounts for each range
     * @return limitWidth The limit width for limit positions
     */
    function executeSwapAndCalculateRanges(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        IMultiPositionManager.RebalanceSwapParams calldata params
    )
        external
        returns (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory liquidities, uint24 limitWidth)
    {
        // 1. Get current balances
        uint256 amount0 = s.currency0.balanceOfSelf();
        uint256 amount1 = s.currency1.balanceOfSelf();

        // 2. Execute swap if needed
        if (params.swapParams.swapData.length > 0) {
            (amount0, amount1) = _executeProvidedSwap(s, params.swapParams, amount0, amount1);
        }

        // 3. Calculate ranges with updated amounts
        return _calculateRebalanceRanges(s, poolManager, params.rebalanceParams, amount0, amount1);
    }

    /**
     * @notice Execute swap for compound operation
     * @dev Used by compoundSwap to execute validated swap between ZERO_BURN and COMPOUND
     * @param s Storage struct
     * @param params Swap parameters including aggregator details
     * @return amount0 Updated amount of token0 after swap
     * @return amount1 Updated amount of token1 after swap
     */
    function executeCompoundSwap(SharedStructs.ManagerStorage storage s, RebalanceLogic.SwapParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        // Get current balances
        amount0 = s.currency0.balanceOfSelf();
        amount1 = s.currency1.balanceOfSelf();

        // Execute swap if swap data provided
        if (params.swapData.length > 0) {
            (amount0, amount1) = _executeProvidedSwap(s, params, amount0, amount1);
        }

        return (amount0, amount1);
    }

    /**
     * @notice Execute swap exactly as specified in swapParams
     * @dev Trusts off-chain calculation from SimpleLens.calculateOptimalSwapForRebalance
     * @param s Storage struct
     * @param swapParams Complete swap parameters from JavaScript including aggregator and calldata
     * @param amount0 Current amount of token0
     * @param amount1 Current amount of token1
     * @return Updated amount0 and amount1 after swap
     */
    function _executeProvidedSwap(
        SharedStructs.ManagerStorage storage s,
        RebalanceLogic.SwapParams calldata swapParams,
        uint256 amount0,
        uint256 amount1
    ) private returns (uint256, uint256) {
        if (swapParams.swapData.length == 0) {
            // No swap needed
            return (amount0, amount1);
        }

        // Get token addresses for swap execution
        address currency0 = Currency.unwrap(s.poolKey.currency0);
        address currency1 = Currency.unwrap(s.poolKey.currency1);

        // Execute aggregator swap with validation
        uint256 amountOut = _executeAggregatorSwap(swapParams, amount0, amount1, currency0, currency1, s.factory);

        emit SwapExecuted(
            IMultiPositionFactory(s.factory).aggregatorAddress(uint8(swapParams.aggregator)),
            swapParams.swapAmount,
            amountOut,
            swapParams.swapToken0
        );

        // Update amounts based on swap direction
        if (swapParams.swapToken0) {
            return (amount0 - swapParams.swapAmount, amount1 + amountOut);
        }
        return (amount0 + amountOut, amount1 - swapParams.swapAmount);
    }

    /**
     * @notice Execute swap through aggregator with validation
     * @dev JavaScript builds complete function call, Solidity just executes it
     * @param params Swap parameters including aggregator type and encoded calldata
     * @param amount0 Available amount of token0
     * @param amount1 Available amount of token1
     * @param currency0 Address of token0
     * @param currency1 Address of token1
     * @return amountOut Amount of output token received
     */
    function _executeAggregatorSwap(
        RebalanceLogic.SwapParams calldata params,
        uint256 amount0,
        uint256 amount1,
        address currency0,
        address currency1,
        address factory
    ) private returns (uint256 amountOut) {
        // Validate aggregator type and address (prevents arbitrary contract calls)
        if (uint8(params.aggregator) > 3) revert InvalidAggregator();
        address approvedAggregator = IMultiPositionFactory(factory).aggregatorAddress(uint8(params.aggregator));
        if (approvedAggregator == address(0) || params.aggregatorAddress != approvedAggregator) {
            revert InvalidAggregator();
        }

        // Validate we have sufficient tokens for the swap
        if (params.swapToken0) {
            if (amount0 < params.swapAmount) revert InsufficientTokensForSwap();
        } else {
            if (amount1 < params.swapAmount) revert InsufficientTokensForSwap();
        }

        // Determine input and output tokens
        address inputToken = params.swapToken0 ? currency0 : currency1;
        address outputToken = params.swapToken0 ? currency1 : currency0;

        // Check if input token is native ETH (address(0))
        bool isETHIn = inputToken == address(0);

        // Approve aggregator to spend input tokens (skip if native ETH)
        if (!isETHIn) {
            IERC20(inputToken).forceApprove(approvedAggregator, params.swapAmount);
        }

        // Record balance before swap
        uint256 balanceBefore = _getBalance(outputToken);

        // Determine ETH value to send with call
        // If swapping native ETH, send the swap amount; otherwise send 0
        uint256 ethValue = isETHIn ? params.swapAmount : 0;

        // Execute the aggregator's function call
        // swapData already contains the complete, ready-to-execute function call from JavaScript
        (bool success,) = approvedAggregator.call{value: ethValue}(params.swapData);

        // Reset approval for security (skip if native ETH)
        if (!isETHIn) {
            IERC20(inputToken).forceApprove(approvedAggregator, 0);
        }

        // Bubble up revert reason if swap failed
        if (!success) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        // Calculate and validate output amount
        amountOut = _getBalance(outputToken) - balanceBefore;
        if (amountOut < params.minAmountOut) revert InsufficientOutput();

        return amountOut;
    }

    /**
     * @notice Get balance of a token (handles both ERC20 and native ETH)
     * @param token Token address (address(0) for native ETH)
     * @return balance Current balance
     */
    function _getBalance(address token) private view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /**
     * @notice Process the rebalance result after swap
     * @dev Helper to avoid stack too deep
     */
    function _calculateRebalanceRanges(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        IMultiPositionManager.RebalanceParams calldata params,
        uint256 amount0,
        uint256 amount1
    )
        private
        returns (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory liquidities, uint24 limitWidth)
    {
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(s.poolKey.toId());
        RebalanceLogic.StrategyContext memory ctx =
            _buildStrategyContext(s, params, amount0, amount1, sqrtPriceX96, currentTick);

        (baseRanges, liquidities) = RebalanceLogic.generateRangesAndLiquidities(s, poolManager, ctx, amount0, amount1);

        RebalanceLogic._updateStrategyParams(s, ctx, true);

        s.basePositionsLength = 0;
        s.limitPositionsLength = 0;

        return (baseRanges, liquidities, ctx.limitWidth);
    }

    /**
     * @notice Build strategy context from params
     */
    function _buildStrategyContext(
        SharedStructs.ManagerStorage storage s,
        IMultiPositionManager.RebalanceParams calldata params,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        int24 currentTick
    ) private view returns (RebalanceLogic.StrategyContext memory ctx) {
        ctx.useAssetWeights = (params.weight0 == 0 && params.weight1 == 0);
        if (ctx.useAssetWeights) {
            (ctx.weight0, ctx.weight1) = RebalanceLogic.calculateWeightsFromAmounts(amount0, amount1, sqrtPriceX96);
        } else {
            ctx.weight0 = params.weight0;
            ctx.weight1 = params.weight1;
        }
        if (!ctx.useAssetWeights && ctx.weight0 + ctx.weight1 != 1e18) {
            revert RebalanceLogic.InvalidWeightSum();
        }

        ctx.resolvedStrategy = params.strategy != address(0) ? params.strategy : s.lastStrategyParams.strategy;

        ctx.center = RebalanceLogic.resolveAndClampCenterTick(params.center, currentTick, s.poolKey.tickSpacing);

        ctx.tLeft = params.tLeft;
        ctx.tRight = params.tRight;
        ctx.useCarpet = params.useCarpet;
        // In proportional mode (weights 0,0), force limitWidth to 0
        // Limit positions don't make sense when weights are derived from amounts
        if (ctx.useAssetWeights) {
            ctx.limitWidth = 0;
        } else {
            ctx.limitWidth = params.limitWidth;
        }

        if (ctx.resolvedStrategy == address(0)) revert NoStrategySpecified();
        ctx.strategy = ILiquidityStrategy(ctx.resolvedStrategy);
    }
}
