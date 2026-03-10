// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IRelayerFactory} from "./interfaces/IRelayerFactory.sol";
import {IRelayer} from "./interfaces/IRelayer.sol";
import {IMultiPositionManager} from "./interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "./interfaces/IMultiPositionFactory.sol";
import {RelayerDeployer} from "./RelayerDeployer.sol";
import {MultiPositionManager} from "./MultiPositionManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IVolatilityDynamicFeeHook} from "./interfaces/IVolatilityDynamicFeeHook.sol";
import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";

/**
 * @title RelayerFactory
 * @notice Factory for deploying Relayer contracts
 * @dev Manages role-based access control for automation services
 */
contract RelayerFactory is IRelayerFactory, Ownable {
    using PoolIdLibrary for PoolKey;

    /// @notice Role identifier for automation services
    bytes32 public constant AUTOMATION_SERVICE_ROLE = keccak256("AUTOMATION_SERVICE");

    /// @notice Reference to MultiPositionFactory for role management
    IMultiPositionFactory public immutable multiPositionFactory;

    /// @notice Deployer contract for Relayer
    RelayerDeployer public immutable deployer;

    /// @notice Role storage: role => account => hasRole
    mapping(bytes32 => mapping(address => bool)) private _roles;

    /// @notice Deployed relayer info: relayer address => RelayerInfo
    mapping(address => RelayerInfo) public relayers;

    /// @notice Relayer by MultiPositionManager: mpm => relayer address (1:1 mapping)
    mapping(address => address) public relayerByManager;

    /// @notice Relayers by owner: owner => relayer addresses
    mapping(address => address[]) public relayersByOwner;

    /// @notice All deployed rebalancers (for pagination)
    address[] private allRelayers;

    /// @notice Protocol fee for automated management (denominator: 10 = 10%)
    uint16 public automatedManagementFee = 10;

    /// @notice Minimum ETH balance required for relayer execution
    uint256 public minBalance = 0.00001 ether;

    /**
     * @notice Construct the RelayerFactory
     * @param _owner The factory owner address
     * @param _multiPositionFactory The MultiPositionFactory for role management
     */
    constructor(address _owner, IMultiPositionFactory _multiPositionFactory) Ownable(_owner) {
        if (_owner == address(0)) revert InvalidAddress();
        if (address(_multiPositionFactory) == address(0)) revert InvalidAddress();
        multiPositionFactory = _multiPositionFactory;
        deployer = new RelayerDeployer(address(this));
    }

    /**
     * @notice Validate TWAP configuration for a pool
     * @param mpm The MultiPositionManager address
     * @param triggerConfig Trigger configuration to validate
     * @param strategyParams Strategy parameters to validate
     * @param twapParams TWAP parameters to validate
     * @dev Reverts if TWAP configuration is invalid or incompatible
     */
    function _validateTwapConfig(
        address mpm,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.TwapParams calldata twapParams
    ) private view {
        // Skip if TWAP not used
        if (!twapParams.useTwapProtection && !twapParams.useTwapCenter && triggerConfig.baseTwapTickTrigger == 0) {
            return;
        }

        // Get poolKey from MPM
        MultiPositionManager manager = MultiPositionManager(payable(mpm));
        PoolKey memory poolKey = manager.poolKey();

        // Check 1: Pool must be managed by VolatilityDynamicFeeHook
        address hookAddress = address(poolKey.hooks);
        if (hookAddress == address(0)) revert IRelayer.PoolNotManagedByVolatilityHook();

        // Try to cast and check managedPools - will revert if not a VolatilityDynamicFeeHook
        try IVolatilityDynamicFeeHook(hookAddress).managedPools(poolKey.toId()) returns (bool isManaged) {
            if (!isManaged) revert IRelayer.PoolNotManagedByVolatilityHook();
        } catch {
            revert IRelayer.PoolNotManagedByVolatilityHook();
        }

        // Check 2: Verify TWAP history availability via oracle
        IVolatilityDynamicFeeHook hook = IVolatilityDynamicFeeHook(hookAddress);
        IVolatilityOracle oracle = hook.volatilityOracle();

        // Validate TWAP history exists for requested period
        try oracle.consult(poolKey, twapParams.twapSeconds) returns (int24, uint128) {
            // TWAP data available
        } catch {
            revert IRelayer.TwapHistoryUnavailable();
        }

        // Check 3: Enforce mutual exclusivity between baseTickTrigger and baseTwapTickTrigger
        bool hasBaseTrigger = (triggerConfig.baseLowerTrigger != 0 || triggerConfig.baseUpperTrigger != 0);
        bool hasTwapTrigger = (triggerConfig.baseTwapTickTrigger != 0);
        if (hasBaseTrigger && hasTwapTrigger) revert IRelayer.MutuallyExclusiveTriggers();

        // Check 4: Prevent useTwapCenter when isBaseRatio=true
        if (twapParams.useTwapCenter && strategyParams.isBaseRatio) {
            revert IRelayer.InvalidTwapConfig();
        }

        // Check 5: Prevent baseTwapTickTrigger when isBaseRatio=true
        if (hasTwapTrigger && strategyParams.isBaseRatio) {
            revert IRelayer.InvalidTwapConfig();
        }

        // Validate twapSeconds is reasonable (not 0, not too large)
        if (twapParams.twapSeconds == 0) revert IRelayer.InvalidTwapConfig();
        if (twapParams.twapSeconds > 7 days) revert IRelayer.InvalidTwapConfig();

        // Validate maxTickDeviation if protection enabled
        if (twapParams.useTwapProtection && twapParams.maxTickDeviation == 0) {
            revert IRelayer.InvalidTwapConfig();
        }
    }

    /**
     * @notice Deploy a new Relayer contract
     * @param mpm The MultiPositionManager to automate
     * @param triggerConfig Initial trigger configuration
     * @param strategyParams Initial strategy parameters
     * @param volatilityParams Volatility parameters for this token pair
     * @param withdrawalParams Initial withdrawal trigger parameters
     * @param compoundSwapParams Initial compound swap trigger parameters
     * @param twapParams TWAP-based protection and centering parameters
     * @return relayer Address of the deployed Relayer
     * @dev Creates a new relayer owned by msg.sender
     * @dev Optionally send ETH to fund the relayer for gas reimbursements
     */
    function deployRelayer(
        address mpm,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external payable override returns (address relayer) {
        // Require minimum funding payment
        if (msg.value < minBalance) revert InsufficientPayment();

        if (mpm == address(0)) revert InvalidAddress();

        // Enforce 1:1 relayer per manager for DDOS protection
        if (relayerByManager[mpm] != address(0)) revert RelayerAlreadyExists();

        // Get the owner of the MultiPositionManager (cast to MultiPositionManager to access Ownable.owner())
        address mpmOwner = MultiPositionManager(payable(mpm)).owner();

        // Only the MPM owner can deploy a relayer for their manager
        if (msg.sender != mpmOwner) revert UnauthorizedAccess();

        // Validate weights: either both 0 (proportional) or sum to 1e18
        _validateWeights(strategyParams.weight0, strategyParams.weight1);

        // Validate withdrawal params for invalid combinations
        _validateWithdrawalParams(withdrawalParams);

        // Validate strategy params to prevent perpetual rebalancing
        _validateStrategyParams(strategyParams);

        // Validate TWAP configuration
        _validateTwapConfig(mpm, triggerConfig, strategyParams, twapParams);

        // Deploy new Relayer using deployer contract
        relayer = deployer.deploy(
            mpm,
            address(this),
            mpmOwner,
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );

        // Fund relayer with the deployment ETH
        (bool success,) = relayer.call{value: msg.value}("");
        if (!success) revert InvalidAddress(); // Reuse existing error

        // Set automated management fee on the MPM
        MultiPositionManager(payable(mpm)).setFee(automatedManagementFee);

        // Store relayer info
        relayers[relayer] = RelayerInfo({
            relayerAddress: relayer,
            multiPositionManager: mpm,
            owner: mpmOwner,
            deployedAt: block.timestamp
        });

        // Track by manager (1:1 mapping)
        relayerByManager[mpm] = relayer;

        // Track by owner
        relayersByOwner[mpmOwner].push(relayer);

        // Track globally
        allRelayers.push(relayer);

        emit RelayerDeployed(relayer, mpm, mpmOwner);

        return relayer;
    }

    /**
     * @notice Compute the address where a Relayer will be deployed
     * @param mpm The MultiPositionManager to automate
     * @param owner The owner of the new Relayer
     * @param triggerConfig Initial trigger configuration
     * @param strategyParams Initial strategy parameters
     * @param volatilityParams Volatility parameters for this token pair
     * @param withdrawalParams Initial withdrawal trigger parameters
     * @param compoundSwapParams Initial compound swap trigger parameters
     * @param twapParams TWAP-based protection and centering parameters
     * @return predicted The predicted address of the Relayer
     * @dev Useful for granting roles before deployment
     * @dev Uses CREATE2 for deterministic address computation
     */
    function computeRelayerAddress(
        address mpm,
        address owner,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external view returns (address predicted) {
        if (mpm == address(0)) revert InvalidAddress();
        address mpmOwner = MultiPositionManager(payable(mpm)).owner();
        if (owner != mpmOwner) revert UnauthorizedAccess();
        return deployer.computeAddress(
            mpm,
            address(this),
            owner,
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );
    }

    /**
     * @notice Check if an account has a specific role
     * @param role The role identifier
     * @param account The account to check
     * @return True if the account has the role
     */
    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return _roles[role][account];
    }

    /**
     * @notice Check if an account has a specific role or is the owner
     * @param role The role identifier
     * @param account The account to check
     * @return True if the account has the role or is the owner
     */
    function hasRoleOrOwner(bytes32 role, address account) external view override returns (bool) {
        return account == owner() || _roles[role][account];
    }

    /**
     * @notice Grant a role to an account
     * @param role The role to grant
     * @param account The account to grant the role to
     * @dev Only callable by owner
     */
    function grantRole(bytes32 role, address account) external override onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    /**
     * @notice Revoke a role from an account
     * @param role The role to revoke
     * @param account The account to revoke the role from
     * @dev Only callable by owner
     */
    function revokeRole(bytes32 role, address account) external override onlyOwner {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    /**
     * @notice Set the automated management fee for newly deployed rebalancers
     * @param _fee The new fee (denominator: 10 = 10%)
     * @dev Only callable by addresses with FEE_MANAGER role in MultiPositionFactory
     */
    function setAutomatedManagementFee(uint16 _fee) external {
        if (!multiPositionFactory.hasRole(multiPositionFactory.FEE_MANAGER(), msg.sender)) revert UnauthorizedAccess();
        if (_fee == 0) revert InvalidAddress();
        automatedManagementFee = _fee;
    }

    function setMinBalance(uint256 newMinBalance) external onlyOwner {
        if (newMinBalance == 0) revert InvalidAddress();
        uint256 oldMinBalance = minBalance;
        minBalance = newMinBalance;
        emit MinBalanceUpdated(oldMinBalance, newMinBalance);
    }

    /**
     * @notice Sync manager fee based on relayer paused state
     * @param mpm The MultiPositionManager address
     * @param paused Whether relayer is paused
     * @dev Callable only by the relayer registered for the manager
     */
    function syncManagerFeeWithPauseState(address mpm, bool paused) external override {
        address relayer = relayerByManager[mpm];
        if (relayer == address(0) || msg.sender != relayer) revert UnauthorizedAccess();

        uint16 targetFee = paused ? multiPositionFactory.protocolFee() : automatedManagementFee;
        MultiPositionManager(payable(mpm)).setFee(targetFee);
    }

    /**
     * @notice Get information about a specific relayer
     * @param relayer The relayer address
     * @return info RelayerInfo struct
     */
    function getRelayerInfo(address relayer) external view override returns (RelayerInfo memory info) {
        info = relayers[relayer];
        if (info.relayerAddress == address(0)) revert InvalidAddress();
        return info;
    }

    /**
     * @notice Get the relayer for a specific MultiPositionManager
     * @param mpm The MultiPositionManager address
     * @return relayerAddress The relayer address (address(0) if none exists)
     */
    function getRelayerByManager(address mpm) external view override returns (address relayerAddress) {
        return relayerByManager[mpm];
    }

    /**
     * @notice Get all relayers owned by a specific address
     * @param ownerAddress The owner address
     * @return relayersArray Array of relayer addresses
     */
    function getRelayersByOwner(address ownerAddress) external view override returns (address[] memory relayersArray) {
        return relayersByOwner[ownerAddress];
    }

    /**
     * @notice Get all deployed relayers with pagination
     * @param offset Starting index
     * @param limit Maximum number to return (0 for all remaining)
     * @return relayersInfo Array of RelayerInfo structs
     * @return totalCount Total number of deployed relayers
     */
    function getAllRelayersPaginated(uint256 offset, uint256 limit)
        external
        view
        override
        returns (RelayerInfo[] memory relayersInfo, uint256 totalCount)
    {
        totalCount = allRelayers.length;

        if (limit == 0) {
            limit = totalCount; // 0 means return all
        }

        if (offset >= totalCount) {
            return (new RelayerInfo[](0), totalCount);
        }

        uint256 count = (offset + limit > totalCount) ? (totalCount - offset) : limit;

        relayersInfo = new RelayerInfo[](count);

        for (uint256 i = 0; i < count;) {
            address relayerAddr = allRelayers[offset + i];
            relayersInfo[i] = relayers[relayerAddr];
            unchecked {
                ++i;
            }
        }

        return (relayersInfo, totalCount);
    }

    /**
     * @notice Get total count of deployed relayers
     * @return count Total number of relayers
     */
    function getTotalRelayersCount() external view override returns (uint256 count) {
        return allRelayers.length;
    }

    /**
     * @notice Get all unique token pairs from automated MultiPositionManagers with pagination
     * @param offset Starting index
     * @param limit Maximum number to return (0 for all)
     * @return tokenPairs Array of unique TokenPairInfo structs
     * @return totalCount Total number of unique token pairs
     * @dev Iterates through all relayers, extracts unique token pairs from their managers
     */
    function getUniqueTokenPairs(uint256 offset, uint256 limit)
        external
        view
        override
        returns (TokenPairInfo[] memory tokenPairs, uint256 totalCount)
    {
        // First pass: collect all unique token pairs
        // Using a simple approach: store pairs in memory and check for duplicates
        TokenPairInfo[] memory tempPairs = new TokenPairInfo[](allRelayers.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < allRelayers.length;) {
            address relayerAddr = allRelayers[i];
            IRelayer relayer = IRelayer(payable(relayerAddr));
            IMultiPositionManager mpm = relayer.manager();

            // Get pool key from manager
            PoolKey memory poolKey = mpm.poolKey();
            address token0 = Currency.unwrap(poolKey.currency0);
            address token1 = Currency.unwrap(poolKey.currency1);

            // Check if this pair already exists in our temp array
            bool isDuplicate = false;
            for (uint256 j = 0; j < uniqueCount;) {
                if (tempPairs[j].token0Address == token0 && tempPairs[j].token1Address == token1) {
                    isDuplicate = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }

            if (!isDuplicate) {
                // Get symbols
                string memory symbol0 = _getTokenSymbol(token0);
                string memory symbol1 = _getTokenSymbol(token1);

                // Get decimals
                uint8 decimals0 = _getTokenDecimals(token0);
                uint8 decimals1 = _getTokenDecimals(token1);

                tempPairs[uniqueCount] = TokenPairInfo({
                    token0Symbol: symbol0,
                    token0Address: token0,
                    token1Symbol: symbol1,
                    token1Address: token1,
                    token0Decimals: decimals0,
                    token1Decimals: decimals1
                });
                unchecked {
                    ++uniqueCount;
                }
            }

            unchecked {
                ++i;
            }
        }

        totalCount = uniqueCount;

        // Handle pagination
        if (limit == 0) {
            limit = totalCount;
        }

        if (offset >= totalCount) {
            return (new TokenPairInfo[](0), totalCount);
        }

        uint256 count = (offset + limit > totalCount) ? (totalCount - offset) : limit;

        tokenPairs = new TokenPairInfo[](count);

        for (uint256 i = 0; i < count;) {
            tokenPairs[i] = tempPairs[offset + i];
            unchecked {
                ++i;
            }
        }

        return (tokenPairs, totalCount);
    }

    /**
     * @notice Helper function to get token symbol
     * @param token The token address
     * @return symbol Token symbol
     */
    function _getTokenSymbol(address token) private view returns (string memory symbol) {
        if (token == address(0)) {
            return "ETH";
        }
        return IERC20Metadata(token).symbol();
    }

    /**
     * @notice Helper function to get token decimals
     * @param token The token address
     * @return decimals Token decimals
     */
    function _getTokenDecimals(address token) private view returns (uint8 decimals) {
        if (token == address(0)) {
            return 18;
        }
        return IERC20Metadata(token).decimals();
    }

    /**
     * @notice Validate weight parameters
     * @param w0 Weight for token0
     * @param w1 Weight for token1
     * @dev Weights must either both be 0 (proportional mode) or sum to 1e18
     */
    function _validateWeights(uint256 w0, uint256 w1) private pure {
        // Proportional mode: both weights must be 0
        if (w0 == 0 && w1 == 0) {
            return;
        }
        // Non-proportional mode: weights must sum to 1e18
        if (w0 + w1 != 1e18) {
            revert InvalidWeightSum();
        }
    }

    /**
     * @notice Validate withdrawal params for invalid combinations
     * @param params The withdrawal params to validate
     * @dev Prevents invalid configurations that would fail or behave incorrectly
     */
    function _validateWithdrawalParams(IRelayer.WithdrawalParams calldata params) private pure {
        if (
            // Cannot set both pool0RatioThreshold and pool1RatioThreshold (mutually exclusive)
            params.pool0RatioThreshold != 0 && params.pool1RatioThreshold != 0
        ) {
            revert InvalidAddress(); // Reuse existing error
        }
    }

    /**
     * @notice Validate strategy params to prevent perpetual rebalancing
     * @param params The strategy params to validate
     * @dev If isBaseRatio=true and proportional mode, must use swap to fix ratio imbalance
     */
    function _validateStrategyParams(IRelayer.StrategyParams calldata params) private pure {
        // If isBaseRatio=true and proportional mode (weight0=0, weight1=0), must use swap
        // Otherwise: perpetual rebalancing (ratio trigger fires, rebalances proportionally, ratio still wrong, triggers again)
        bool isProportional = (params.weight0 == 0 && params.weight1 == 0);
        if (params.isBaseRatio && isProportional && !params.useRebalanceSwap) {
            revert InvalidAddress(); // Reuse existing error
        }

        if (params.useRebalanceSwap) {
            if (params.maxSwapSlippageBps == 0 || params.maxSwapSlippageBps > 10_000) {
                revert InvalidAddress(); // Reuse existing error
            }
        } else if (params.maxSwapSlippageBps != 0) {
            revert InvalidAddress(); // Reuse existing error
        }
    }
}
