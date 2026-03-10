// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMultiPositionManager} from "./IMultiPositionManager.sol";
import {IRelayerFactory} from "./IRelayerFactory.sol";
import {RebalanceLogic} from "../libraries/RebalanceLogic.sol";

interface IRelayer {
    /// @notice TWAP-based protection and centering parameters
    struct TwapParams {
        bool useTwapProtection; // Check if current price deviates too far from TWAP (revert if exceeded)
        bool useTwapCenter; // Center new positions around TWAP tick instead of current tick
        uint32 twapSeconds; // TWAP period in seconds (e.g., 1800 = 30 minutes)
        uint24 maxTickDeviation; // Maximum allowed tick deviation from TWAP
    }

    /// @notice Configuration for rebalance triggers
    struct TriggerConfig {
        // Tick-based triggers (absolute deviation from centerTick of last rebalance)
        uint24 baseLowerTrigger; // Tick deviation threshold below center for base trigger (e.g., 50 ticks)
        uint24 baseUpperTrigger; // Tick deviation threshold above center for base trigger (e.g., 50 ticks)
        uint24 limitDeltaTicks; // Tick deviation threshold for limit trigger (e.g., 30 ticks)
        uint24 maxDeltaTicks; // Maximum allowed tick deviation (flashloan/depeg protection)
        // TWAP-based base trigger (mutually exclusive with baseLowerTrigger/baseUpperTrigger)
        uint24 baseTwapTickTrigger; // Tick deviation threshold from last rebalance centerTick for TWAP-based trigger
        // Ratio-based triggers
        uint256 baseMinRatio; // Minimum base0Ratio (1e18 = 100%)
        uint256 baseMaxRatio; // Maximum base0Ratio (1e18 = 100%)
        uint256 limitMinRatio; // Minimum conversion ratio to trigger (e.g., 0.8e18 = 80% converted)
        uint256 limitThreshold; // Prerequisite: limitRatio must exceed this (e.g., 0.2e18 = 20%)
        // Global triggers
        uint256 outOfPositionThreshold; // Trigger when outOfPositionRatio exceeds this (e.g., 0.05e18 = 5%)
    }

    /// @notice Strategy parameters for rebalance execution
    struct StrategyParams {
        uint24 ticksLeft; // Left tick range from center
        uint24 ticksRight; // Right tick range from center
        bool useCarpet; // Whether to use full-range floor
        uint24 limitWidth; // Width for limit positions
        address strategy; // Strategy contract address
        uint256 weight0; // Weight for token0 (weight0 = 0, weight1 = 0 means proportional mode)
        uint256 weight1; // Weight for token1 (sum of weights should be 1e18 if not proportional)
        bool isolatedBaseLimitRebalancing; // If true, limit rebalances independently; if false, coupled
        bool useRebalanceSwap; // If true, uses rebalanceSwap; if false, uses rebalance
        bool isBaseRatio; // If true, enables base ratio triggers
        bool compoundFees; // If true, fees compound into positions; if false, fees claimed to owner before rebalance
        uint16 maxSwapSlippageBps; // Max allowed swap slippage in bps for rebalanceSwap (1 = 0.01%)
    }

    /// @notice Statistics tracking for the relayer
    struct RelayerStats {
        uint256 totalGasSpent; // Cumulative gas costs paid out (in wei)
        uint256 ethBalance; // Current ETH balance for reimbursements
    }

    /// @notice Information about which rebalance triggers are currently met
    struct RebalanceTriggerStatus {
        bool baseTickTrigger;
        bool baseTwapTickTrigger; // TWAP-based base trigger
        bool baseRatioTrigger;
        bool limitTickTrigger;
        bool limitRatioTrigger;
        bool outOfPositionTrigger;
        bool anyTriggerMet; // True if any trigger is met
    }

    /// @notice Configuration for withdrawal triggers
    struct WithdrawalParams {
        uint256 pool0RatioThreshold; // Trigger when pool0Ratio >= this (1e18 = 100%, 0 = disabled)
        uint256 pool1RatioThreshold; // Trigger when pool1Ratio >= this (1e18 = 100%, 0 = disabled)
    }

    /// @notice Configuration for compound swap triggers
    struct CompoundSwapParams {
        uint256 outOfPositionRatioThreshold; // Trigger when outOfPositionRatio >= this (1e18 = 100%, 0 = disabled)
    }

    /// @notice Token pair information
    struct TokenInfo {
        string token0Symbol;
        string token1Symbol;
        address token0Address;
        address token1Address;
        uint8 decimals0;
        uint8 decimals1;
        string token0CoingeckoId;
        string token1CoingeckoId;
    }

    /// @notice Volatility parameters for the token pair
    /// @dev Used for monitoring and volatility-aware strategies
    struct VolatilityParams {
        string geckoIdToken0; // Coingecko ID for token0 (empty string if not applicable)
        string geckoIdToken1; // Coingecko ID for token1 (empty string if not applicable)
        uint8 pairType; // 0=stable-stable, 1=forex/LST, 2=narrow volatile, 3=wide volatile
    }

    /// @notice Consolidated state for all relayer configuration and status
    /// @dev Consolidates all config structs and operational state into single storage struct
    struct RelayerState {
        TriggerConfig triggerConfig; // Current trigger configuration
        StrategyParams strategyParams; // Current strategy parameters
        VolatilityParams volatilityParams; // Volatility parameters for this token pair
        WithdrawalParams withdrawalParams; // Withdrawal trigger parameters
        CompoundSwapParams compoundSwapParams; // Compound swap trigger parameters
        TwapParams twapParams; // TWAP parameters for this relayer
        bool isPaused; // Whether the contract is paused
        uint256 totalGasSpent; // Cumulative gas costs paid out (in wei)
    }

    // Events
    // triggerIndex: 0=baseTickTrigger, 1=baseTwapTickTrigger, 2=baseRatioTrigger, 3=limitTickTrigger, 4=limitRatioTrigger, 5=outOfPositionTrigger
    event AutomatedRebalanceExecuted(uint8 triggerIndex, bool isSwap);
    event AutomatedCompoundExecuted(
        uint256 outOfPositionRatio, uint256 outOfPositionRatioThreshold, address indexed mpm
    );
    event AutomatedWithdrawalExecuted(bool pool0Triggered, bool pool1Triggered, address indexed mpm);
    event TriggersUpdated(address indexed updater);
    event Paused(address indexed pauser);
    event Unpaused(address indexed unpauser);
    event VolatilityParamsUpdated(string geckoIdToken0, string geckoIdToken1, uint8 pairType);
    event TwapProtectionTriggered(int24 currentTick, int24 twapTick, uint24 deviation);
    event TwapCenterUsed(int24 twapTick, uint32 twapSeconds);

    // Errors
    error UnauthorizedCaller();
    error ContractPaused();
    error NoTriggersmet();
    error InsufficientFunds();
    error InvalidTriggerConfig();
    error TransferFailed();
    error NotPaused();
    error InvalidPairType();
    error InvalidWithdrawalParams();
    error TwapHistoryUnavailable();
    error TwapDeviationExceeded();
    error InvalidTwapConfig();
    error MutuallyExclusiveTriggers();
    error PoolNotManagedByVolatilityHook();

    // Core execution functions
    function executeRebalance(uint256[2][] memory outMin, uint256[2][] memory inMin) external;

    function executeRebalanceSwap(
        RebalanceLogic.SwapParams calldata swapParams,
        uint256[2][] memory outMin,
        uint256[2][] memory inMin
    ) external payable;

    function executeCompoundSwap(RebalanceLogic.SwapParams calldata swapParams, uint256[2][] calldata inMin)
        external
        payable;

    // View functions
    function getRebalanceParams()
        external
        view
        returns (
            TriggerConfig memory triggerConfig,
            StrategyParams memory strategyParams,
            VolatilityParams memory volatilityParams,
            TwapParams memory twapParams
        );
    // function getTriggerConfig() external view returns (TriggerConfig memory);
    // function getStrategyParams() external view returns (StrategyParams memory);
    // function getStats() external view returns (RelayerStats memory);
    // function estimateRebalancesLeft(uint256 estimatedGasPerRebalance) external view returns (uint256);
    // function getVolatilityParams() external view returns (VolatilityParams memory);
    function getWithdrawalParams() external view returns (WithdrawalParams memory);
    function getCompoundSwapParams() external view returns (CompoundSwapParams memory);
    function manager() external view returns (IMultiPositionManager);
    function factory() external view returns (IRelayerFactory);
    function owner() external view returns (address);
    function isPaused() external view returns (bool);
    function minBalance() external view returns (uint256);

    // Owner functions
    // function updateTriggers(TriggerConfig calldata newConfig) external;
    // function updateStrategyParams(StrategyParams calldata newParams) external;
    // function updateVolatilityParams(VolatilityParams calldata newParams) external;
    function setRebalanceParams(
        TriggerConfig calldata triggerConfig,
        StrategyParams calldata strategyParams,
        VolatilityParams calldata volatilityParams,
        TwapParams calldata twapParams
    ) external;
    function setWithdrawalParams(WithdrawalParams calldata newParams) external;
    function setCompoundSwapParams(CompoundSwapParams calldata newParams) external;
    function executeWithdrawal(uint256[2][] memory outMin) external;
    function pause() external;
    function unpause() external;
    function fundContract() external payable;
    function withdrawFunds(uint256 amount) external;
//     function withdrawAllFunds() external;
}
