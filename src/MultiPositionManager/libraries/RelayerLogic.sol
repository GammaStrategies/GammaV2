// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IRelayer} from "../interfaces/IRelayer.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {IVolatilityDynamicFeeHook} from "../interfaces/IVolatilityDynamicFeeHook.sol";
import {IVolatilityOracle} from "../interfaces/IVolatilityOracle.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title RebalancerLogic
 * @notice Library containing core rebalancing logic for trigger checking and parameter construction
 * @dev Extracted from Rebalancer.sol to conceal implementation details while maintaining reusability
 */
library RelayerLogic {
    using PoolIdLibrary for PoolKey;
    /**
     * @notice Get TWAP tick from VolatilityOracle
     * @param manager The MultiPositionManager
     * @param twapSeconds TWAP period in seconds
     * @return twapTick The TWAP tick
     */
    function _getTwapTick(IMultiPositionManager manager, uint32 twapSeconds)
        private
        view
        returns (int24 twapTick)
    {
        PoolKey memory poolKey = manager.poolKey();
        address hookAddress = address(poolKey.hooks);

        IVolatilityDynamicFeeHook hook = IVolatilityDynamicFeeHook(hookAddress);
        IVolatilityOracle oracle = hook.volatilityOracle();

        (twapTick,) = oracle.consult(poolKey, twapSeconds);
        return twapTick;
    }

    /**
     * @notice Validate TWAP parameters
     * @param manager The MultiPositionManager
     * @param twapParams TWAP parameters to validate
     * @param triggerConfig Trigger configuration
     * @param strategyParams Strategy parameters
     * @dev Mirrors factory validation to prevent post-deploy misconfiguration
     */
    function validateTwapParams(
        IMultiPositionManager manager,
        IRelayer.TwapParams memory twapParams,
        IRelayer.TriggerConfig memory triggerConfig,
        IRelayer.StrategyParams memory strategyParams
    ) external view {
        // Skip if TWAP not used
        if (!twapParams.useTwapProtection && !twapParams.useTwapCenter && triggerConfig.baseTwapTickTrigger == 0) {
            return;
        }

        // Check 1: Mutual exclusivity between baseTickTrigger and baseTwapTickTrigger
        bool hasBaseTrigger = (triggerConfig.baseLowerTrigger != 0 || triggerConfig.baseUpperTrigger != 0);
        bool hasTwapTrigger = (triggerConfig.baseTwapTickTrigger != 0);
        if (hasBaseTrigger && hasTwapTrigger) revert IRelayer.InvalidTriggerConfig();

        // Check 2: Prevent useTwapCenter with isBaseRatio
        if (twapParams.useTwapCenter && strategyParams.isBaseRatio) {
            revert IRelayer.InvalidTwapConfig();
        }

        // Check 3: Prevent baseTwapTickTrigger with isBaseRatio
        if (hasTwapTrigger && strategyParams.isBaseRatio) {
            revert IRelayer.InvalidTwapConfig();
        }

        // Check 4: Validate twapSeconds bounds (before external calls)
        if (twapParams.twapSeconds == 0) revert IRelayer.InvalidTwapConfig();
        if (twapParams.twapSeconds > 7 days) revert IRelayer.InvalidTwapConfig();

        // Check 5: Validate maxTickDeviation if protection enabled
        if (twapParams.useTwapProtection && twapParams.maxTickDeviation == 0) {
            revert IRelayer.InvalidTwapConfig();
        }

        // Get poolKey from manager for hook/oracle checks
        PoolKey memory poolKey = manager.poolKey();

        // Check 6: Pool must be managed by VolatilityDynamicFeeHook
        address hookAddress = address(poolKey.hooks);
        if (hookAddress == address(0)) revert IRelayer.PoolNotManagedByVolatilityHook();

        // Try to cast and check managedPools - will revert if not a VolatilityDynamicFeeHook
        try IVolatilityDynamicFeeHook(hookAddress).managedPools(poolKey.toId()) returns (bool isManaged) {
            if (!isManaged) revert IRelayer.PoolNotManagedByVolatilityHook();
        } catch {
            revert IRelayer.PoolNotManagedByVolatilityHook();
        }

        // Check 7: Verify TWAP history availability via oracle
        IVolatilityDynamicFeeHook hook = IVolatilityDynamicFeeHook(hookAddress);
        IVolatilityOracle oracle = hook.volatilityOracle();

        // Validate TWAP history exists for requested period
        try oracle.consult(poolKey, twapParams.twapSeconds) returns (int24, uint128) {
            // TWAP data available
        } catch {
            revert IRelayer.TwapHistoryUnavailable();
        }
    }

    /**
     * @notice Check if current tick is within acceptable deviation from TWAP
     * @param manager The MultiPositionManager
     * @param twapParams TWAP parameters
     * @dev Reverts if deviation exceeds maxTickDeviation
     */
    function checkTwapProtection(IMultiPositionManager manager, IRelayer.TwapParams memory twapParams) external {
        if (!twapParams.useTwapProtection) return;

        int24 twapTick = _getTwapTick(manager, twapParams.twapSeconds);
        int24 currentTick = manager.currentTick();

        int24 tickDelta = currentTick - twapTick;
        uint256 absDelta = tickDelta >= 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));

        if (absDelta > twapParams.maxTickDeviation) {
            emit IRelayer.TwapProtectionTriggered(currentTick, twapTick, uint24(absDelta));
            revert IRelayer.TwapDeviationExceeded();
        }
    }

    /**
     * @notice Check all configured triggers to determine if rebalance should execute
     * @param manager The MultiPositionManager to check
     * @param triggerConfig The trigger configuration
     * @param strategyParams The strategy parameters
     * @param twapParams The TWAP parameters
     * @return status Struct indicating which triggers are currently met
     * @dev Optimized to minimize external calls by batching and conditional execution
     */
    function checkTriggers(
        IMultiPositionManager manager,
        IRelayer.TriggerConfig memory triggerConfig,
        IRelayer.StrategyParams memory strategyParams,
        IRelayer.TwapParams memory twapParams
    ) external view returns (IRelayer.RebalanceTriggerStatus memory status) {
        bool isProportional = (strategyParams.weight0 == 0 && strategyParams.weight1 == 0);

        // Check tick-based triggers (pass twapParams for baseTwapTickTrigger)
        status = _checkTickTriggers(manager, triggerConfig, twapParams, isProportional, status);

        // Check ratio-based triggers if not circuit broken
        if (status.baseTickTrigger || status.baseTwapTickTrigger || !_isCircuitBroken(manager, triggerConfig)) {
            status = _checkRatioTriggers(manager, triggerConfig, strategyParams, status);
        }

        status.anyTriggerMet = status.baseTickTrigger || status.baseTwapTickTrigger || status.baseRatioTrigger
            || status.limitTickTrigger || status.limitRatioTrigger || status.outOfPositionTrigger;
    }

    function _isCircuitBroken(IMultiPositionManager manager, IRelayer.TriggerConfig memory triggerConfig)
        private
        view
        returns (bool)
    {
        if (triggerConfig.maxDeltaTicks == 0) return false;

        (, int24 centerTick,,,,,,,,) = manager.lastStrategyParams();
        int24 rawCurrentTick = manager.currentTick();
        int24 tickSpacing = manager.poolKey().tickSpacing;
        int24 currentTick = rawCurrentTick >= 0
            ? (rawCurrentTick / tickSpacing) * tickSpacing
            : ((rawCurrentTick - tickSpacing + 1) / tickSpacing) * tickSpacing;

        int24 tickDelta = currentTick - centerTick;
        uint256 absDelta = tickDelta >= 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));

        return absDelta > triggerConfig.maxDeltaTicks;
    }

    function _checkTickTriggers(
        IMultiPositionManager manager,
        IRelayer.TriggerConfig memory triggerConfig,
        IRelayer.TwapParams memory twapParams,
        bool isProportional,
        IRelayer.RebalanceTriggerStatus memory status
    ) private view returns (IRelayer.RebalanceTriggerStatus memory) {
        bool needTickChecks = (triggerConfig.baseLowerTrigger != 0 || triggerConfig.baseUpperTrigger != 0)
            || triggerConfig.baseTwapTickTrigger != 0
            || (!isProportional && (triggerConfig.limitDeltaTicks != 0 || triggerConfig.limitMinRatio != 0));

        if (!needTickChecks) return status;

        (, int24 centerTick,,,,,,,,) = manager.lastStrategyParams();
        int24 rawCurrentTick = manager.currentTick();
        int24 tickSpacing = manager.poolKey().tickSpacing;
        int24 currentTick = rawCurrentTick >= 0
            ? (rawCurrentTick / tickSpacing) * tickSpacing
            : ((rawCurrentTick - tickSpacing + 1) / tickSpacing) * tickSpacing;

        int24 tickDelta = currentTick - centerTick;
        uint256 absDelta = tickDelta >= 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));

        // Circuit breaker check
        if (triggerConfig.maxDeltaTicks != 0) {
            if (absDelta > triggerConfig.maxDeltaTicks) {
                return status;
            }
        }

        // Check base tick trigger with asymmetric thresholds
        if (triggerConfig.baseLowerTrigger != 0 || triggerConfig.baseUpperTrigger != 0) {
            bool triggered = false;

            if (tickDelta > 0) {
                // Price moved up (above center) - check upper trigger
                triggered = (
                    triggerConfig.baseUpperTrigger != 0 && uint256(int256(tickDelta)) >= triggerConfig.baseUpperTrigger
                );
            } else if (tickDelta < 0) {
                // Price moved down (below center) - check lower trigger
                triggered = (triggerConfig.baseLowerTrigger != 0 && absDelta >= triggerConfig.baseLowerTrigger);
            }

            // Also check against circuit breaker if set
            status.baseTickTrigger =
                triggered && (triggerConfig.maxDeltaTicks == 0 || absDelta <= triggerConfig.maxDeltaTicks);
        }

        // Check TWAP-based base trigger
        if (triggerConfig.baseTwapTickTrigger != 0) {
            int24 twapTick = _getTwapTick(manager, twapParams.twapSeconds);
            int24 twapDelta = twapTick - centerTick;
            uint256 absTwapDelta = twapDelta >= 0 ? uint256(int256(twapDelta)) : uint256(int256(-twapDelta));

            status.baseTwapTickTrigger = absTwapDelta >= triggerConfig.baseTwapTickTrigger
                && (triggerConfig.maxDeltaTicks == 0 || absDelta <= triggerConfig.maxDeltaTicks);
        }

        return status;
    }

    function _checkRatioTriggers(
        IMultiPositionManager manager,
        IRelayer.TriggerConfig memory triggerConfig,
        IRelayer.StrategyParams memory strategyParams,
        IRelayer.RebalanceTriggerStatus memory status
    ) private view returns (IRelayer.RebalanceTriggerStatus memory) {
        bool needRatios = (
            strategyParams.isBaseRatio && (triggerConfig.baseMinRatio != 0 || triggerConfig.baseMaxRatio != 0)
        ) || triggerConfig.limitMinRatio != 0 || triggerConfig.limitDeltaTicks != 0
            || triggerConfig.outOfPositionThreshold != 0;

        if (!needRatios) return status;

        (
            ,
            ,
            ,
            ,
            ,
            uint256 outOfPositionRatio,
            ,
            uint256 limitRatio,
            uint256 base0Ratio,
            ,
            uint256 limit0Ratio,
            uint256 limit1Ratio
        ) = manager.getRatios();

        // Check base ratio trigger
        if (strategyParams.isBaseRatio && (triggerConfig.baseMinRatio != 0 || triggerConfig.baseMaxRatio != 0)) {
            status.baseRatioTrigger = base0Ratio < triggerConfig.baseMinRatio || base0Ratio > triggerConfig.baseMaxRatio;
        }

        // Check limit tick trigger
        if (triggerConfig.limitDeltaTicks != 0) {
            status.limitTickTrigger = _checkLimitTickTrigger(manager, triggerConfig);
        }

        // Check limit ratio trigger
        if (triggerConfig.limitMinRatio != 0 && limitRatio > triggerConfig.limitThreshold) {
            status.limitRatioTrigger =
                checkLimitRatioTrigger(manager, limit0Ratio, limit1Ratio, triggerConfig.limitMinRatio);
        }

        // Check out of position trigger
        if (triggerConfig.outOfPositionThreshold != 0) {
            status.outOfPositionTrigger = outOfPositionRatio > triggerConfig.outOfPositionThreshold;
        }

        return status;
    }

    /**
     * @notice Check limit tick trigger based on active limit position boundaries
     * @param manager The MultiPositionManager to check
     * @param triggerConfig The trigger configuration
     * @return triggered True if limit tick trigger is met
     */
    function _checkLimitTickTrigger(IMultiPositionManager manager, IRelayer.TriggerConfig memory triggerConfig)
        private
        view
        returns (bool triggered)
    {
        uint256 limitLength = manager.limitPositionsLength();
        if (limitLength == 0) return false;

        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        // Determine which limit position has more liquidity and use it
        IMultiPositionManager.Range memory activeLimitRange;
        if (
            limitLength == 2 && positionData[ranges.length - 2].liquidity > positionData[ranges.length - 1].liquidity
                && positionData[ranges.length - 2].liquidity > 0
        ) {
            activeLimitRange = ranges[ranges.length - 2];
        } else if (positionData[ranges.length - 1].liquidity > 0) {
            activeLimitRange = ranges[ranges.length - 1];
        } else {
            return false;
        }

        int24 currentTick = manager.currentTick();

        // Check if current tick is inside the limit position range
        if (currentTick >= activeLimitRange.lowerTick && currentTick < activeLimitRange.upperTick) {
            return false;
        } else if (currentTick < activeLimitRange.lowerTick) {
            // Below limit position: trigger if distance > limitDeltaTicks
            triggered = uint256(int256(activeLimitRange.lowerTick - currentTick)) > triggerConfig.limitDeltaTicks;
        } else {
            // At or above limit position: trigger if distance >= limitDeltaTicks
            triggered = uint256(int256(currentTick - activeLimitRange.upperTick)) >= triggerConfig.limitDeltaTicks;
        }

        // Apply circuit breaker (maxDeltaTicks) if set
        if (triggered && triggerConfig.maxDeltaTicks != 0) {
            int24 tickDelta;
            (, tickDelta,,,,,,,,) = manager.lastStrategyParams();
            tickDelta = currentTick - tickDelta;
            triggered = (tickDelta >= 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta)))
                <= triggerConfig.maxDeltaTicks;
        }
    }

    /// @dev Position ID used for all MPM positions in Uniswap V4
    bytes32 private constant POSITION_ID = bytes32(uint256(1));

    /**
     * @notice Check limit ratio trigger based on position with higher liquidity
     * @param manager The MultiPositionManager to check
     * @param limit0Ratio Current limit0Ratio
     * @param limit1Ratio Current limit1Ratio
     * @param limitMinRatio Minimum ratio threshold
     * @return triggered True if limit ratio trigger is met
     * @dev Uses position index to determine direction (limitPos0=below, limitPos1=above by design)
     */
    function checkLimitRatioTrigger(
        IMultiPositionManager manager,
        uint256 limit0Ratio,
        uint256 limit1Ratio,
        uint256 limitMinRatio
    ) public view returns (bool triggered) {
        if (manager.limitPositionsLength() == 0) return false;

        // Get limit positions and determine which to check
        IMultiPositionManager.Range memory limitPos0 = manager.limitPositions(0);
        IMultiPositionManager.Range memory limitPos1 = manager.limitPositions(1);

        bool hasLimit0 = limitPos0.lowerTick < limitPos0.upperTick;
        bool hasLimit1 = limitPos1.lowerTick < limitPos1.upperTick;

        bool checkLimit0;
        if (hasLimit0 && !hasLimit1) {
            checkLimit0 = true;
        } else if (!hasLimit0 && hasLimit1) {
            checkLimit0 = false;
        } else {
            // Both exist - query liquidity via StateLibrary
            checkLimit0 = _getLimitWithMoreLiquidity(manager, limitPos0, limitPos1);
        }

        // By design (PositionLogic.sol): limitPos0 is below center, limitPos1 is above center
        // - limitPos0 (below): originally token1, converts to token0 → check limit0Ratio
        // - limitPos1 (above): originally token0, converts to token1 → check limit1Ratio
        return checkLimit0 ? limit0Ratio >= limitMinRatio : limit1Ratio >= limitMinRatio;
    }

    function _getLimitWithMoreLiquidity(
        IMultiPositionManager manager,
        IMultiPositionManager.Range memory limitPos0,
        IMultiPositionManager.Range memory limitPos1
    ) private view returns (bool isLimit0) {
        PoolId poolId = manager.poolKey().toId();
        address mpmAddr = address(manager);
        (uint128 liq0,,) = StateLibrary.getPositionInfo(
            manager.poolManager(), poolId, mpmAddr, limitPos0.lowerTick, limitPos0.upperTick, POSITION_ID
        );
        (uint128 liq1,,) = StateLibrary.getPositionInfo(
            manager.poolManager(), poolId, mpmAddr, limitPos1.lowerTick, limitPos1.upperTick, POSITION_ID
        );
        return liq0 >= liq1;
    }

    /**
     * @notice Construct rebalance parameters based on trigger status
     * @param manager The MultiPositionManager
     * @param strategyParams The strategy parameters
     * @param twapParams The TWAP parameters
     * @param status The trigger status from checkTriggers
     * @return params The constructed RebalanceParams for execution
     * @dev Determines whether to use current tick (sentinel), TWAP tick, or previous center tick
     */
    function constructRebalanceParams(
        IMultiPositionManager manager,
        IRelayer.StrategyParams memory strategyParams,
        IRelayer.TwapParams memory twapParams,
        IRelayer.RebalanceTriggerStatus memory status
    ) external view returns (IMultiPositionManager.RebalanceParams memory params) {
        // Determine if using TWAP tick as center
        bool useTwapCenterValue = status.baseTwapTickTrigger || twapParams.useTwapCenter;

        // Determine if using SENTINEL_VALUE or previous centerTick
        bool useSentinelValue = status.baseTickTrigger || status.baseRatioTrigger
            || (status.limitTickTrigger && !strategyParams.isolatedBaseLimitRebalancing);

        // Set centerTick (priority: TWAP > Sentinel > Previous)
        if (useTwapCenterValue) {
            // Use TWAP tick as center
            params.center = _getTwapTick(manager, twapParams.twapSeconds);
        } else if (useSentinelValue) {
            params.center = type(int24).max;
        } else {
            (, params.center,,,,,,,,) = manager.lastStrategyParams();
        }

        // Set weights - always use strategy params
        // Proportional weights (0,0) signal to use current position ratios
        if (strategyParams.weight0 == 0 && strategyParams.weight1 == 0) {
            params.weight0 = 0;
            params.weight1 = 0;
        } else {
            params.weight0 = strategyParams.weight0;
            params.weight1 = strategyParams.weight1;
        }

        // Set other params from strategyParams (inline to save stack)
        params.strategy = strategyParams.strategy;
        params.tLeft = strategyParams.ticksLeft;
        params.tRight = strategyParams.ticksRight;
        params.limitWidth = strategyParams.limitWidth;
        params.useCarpet = strategyParams.useCarpet;
    }

    /**
     * @notice Validate withdrawal params for invalid combinations
     * @param params The withdrawal params to validate
     * @dev Reverts if both thresholds are non-zero (mutually exclusive)
     */
    function validateWithdrawalParams(IRelayer.WithdrawalParams memory params) public pure {
        if (
            // Cannot set both pool0RatioThreshold and pool1RatioThreshold (mutually exclusive)
            params.pool0RatioThreshold != 0 && params.pool1RatioThreshold != 0
        ) {
            revert IRelayer.InvalidWithdrawalParams();
        }
    }
}
