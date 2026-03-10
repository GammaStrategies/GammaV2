// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IRelayer} from "./IRelayer.sol";
import {IMultiPositionFactory} from "./IMultiPositionFactory.sol";

interface IRelayerFactory {
    /// @notice Get the automation service role identifier
    /// @return The role hash
    function AUTOMATION_SERVICE_ROLE() external pure returns (bytes32);

    /// @notice Get the MultiPositionFactory address
    /// @return The MultiPositionFactory interface
    function multiPositionFactory() external view returns (IMultiPositionFactory);

    /// @notice Information about a deployed relayer
    struct RelayerInfo {
        address relayerAddress;
        address multiPositionManager;
        address owner;
        uint256 deployedAt;
    }

    /// @notice Token pair information
    struct TokenPairInfo {
        string token0Symbol;
        address token0Address;
        string token1Symbol;
        address token1Address;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    // Events
    event RelayerDeployed(address indexed relayer, address indexed multiPositionManager, address indexed owner);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event MinBalanceUpdated(uint256 oldMinBalance, uint256 newMinBalance);

    // Errors
    error InvalidAddress();
    error UnauthorizedAccess();
    error RelayerAlreadyExists();
    error InsufficientPayment();
    error InvalidWeightSum();

    /// @notice Deploy a new Relayer contract
    /// @param mpm The MultiPositionManager to automate
    /// @param triggerConfig Initial trigger configuration
    /// @param strategyParams Initial strategy parameters
    /// @param volatilityParams Volatility parameters for this token pair
    /// @param withdrawalParams Initial withdrawal trigger parameters
    /// @param compoundSwapParams Initial compound swap trigger parameters
    /// @param twapParams TWAP-based protection and centering parameters
    /// @return relayer Address of the deployed Relayer
    /// @dev Optionally send ETH to fund the relayer for gas reimbursements
    function deployRelayer(
        address mpm,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external payable returns (address relayer);

    /// @notice Compute the address where a Relayer will be deployed
    /// @param mpm The MultiPositionManager to automate
    /// @param owner The owner of the new Relayer
    /// @param triggerConfig Initial trigger configuration
    /// @param strategyParams Initial strategy parameters
    /// @param volatilityParams Volatility parameters for this token pair
    /// @param withdrawalParams Initial withdrawal trigger parameters
    /// @param compoundSwapParams Initial compound swap trigger parameters
    /// @param twapParams TWAP-based protection and centering parameters
    /// @return predicted The predicted address of the Relayer
    /// @dev Useful for granting roles before deployment (uses CREATE2)
    function computeRelayerAddress(
        address mpm,
        address owner,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external view returns (address predicted);

    /// @notice Check if an account has a specific role
    /// @param role The role identifier
    /// @param account The account to check
    /// @return True if the account has the role
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice Check if an account has a specific role or is the owner
    /// @param role The role identifier
    /// @param account The account to check
    /// @return True if the account has the role or is the owner
    function hasRoleOrOwner(bytes32 role, address account) external view returns (bool);

    /// @notice Grant a role to an account (owner only)
    /// @param role The role to grant
    /// @param account The account to grant the role to
    function grantRole(bytes32 role, address account) external;

    /// @notice Revoke a role from an account (owner only)
    /// @param role The role to revoke
    /// @param account The account to revoke the role from
    function revokeRole(bytes32 role, address account) external;

    /// @notice Get the automated management fee
    /// @return The fee denominator (10 = 10%)
    function automatedManagementFee() external view returns (uint16);

    /// @notice Get the minimum ETH balance required for relayer execution
    /// @return The minimum balance amount in wei
    function minBalance() external view returns (uint256);

    /// @notice Set the automated management fee
    /// @param _fee The new fee (denominator: 10 = 10%)
    function setAutomatedManagementFee(uint16 _fee) external;

    /// @notice Set the minimum ETH balance required for relayer execution (owner only)
    /// @param newMinBalance The new minimum balance amount in wei
    function setMinBalance(uint256 newMinBalance) external;

    /// @notice Sync manager fee with relayer paused/unpaused state
    /// @param mpm The MultiPositionManager address
    /// @param paused Whether the relayer is paused
    function syncManagerFeeWithPauseState(address mpm, bool paused) external;

    /// @notice Get information about a specific relayer
    /// @param relayer The relayer address
    /// @return info RelayerInfo struct
    function getRelayerInfo(address relayer) external view returns (RelayerInfo memory info);

    /// @notice Get the relayer for a specific MultiPositionManager
    /// @param mpm The MultiPositionManager address
    /// @return relayer The relayer address (address(0) if none exists)
    function getRelayerByManager(address mpm) external view returns (address relayer);

    /// @notice Get all relayers owned by a specific address
    /// @param owner The owner address
    /// @return relayers Array of relayer addresses
    function getRelayersByOwner(address owner) external view returns (address[] memory relayers);

    /// @notice Get all deployed relayers with pagination
    /// @param offset Starting index
    /// @param limit Maximum number to return (0 for all)
    /// @return relayersInfo Array of RelayerInfo structs
    /// @return totalCount Total number of deployed relayers
    function getAllRelayersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (RelayerInfo[] memory relayersInfo, uint256 totalCount);

    /// @notice Get total count of deployed relayers
    /// @return count Total number of relayers
    function getTotalRelayersCount() external view returns (uint256 count);

    /// @notice Get all unique token pairs from automated MultiPositionManagers with pagination
    /// @param offset Starting index
    /// @param limit Maximum number to return (0 for all)
    /// @return tokenPairs Array of unique TokenPairInfo structs
    /// @return totalCount Total number of unique token pairs
    function getUniqueTokenPairs(uint256 offset, uint256 limit)
        external
        view
        returns (TokenPairInfo[] memory tokenPairs, uint256 totalCount);
}
