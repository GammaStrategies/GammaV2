// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IMultiPositionFactory {
    // Manager info struct
    struct ManagerInfo {
        address managerAddress; // Note: only used when returning from getters
        address managerOwner;
        PoolKey poolKey;
        string name;
    }

    // Token pair info struct
    struct TokenPairInfo {
        address currency0;
        address currency1;
        uint256 managerCount;
    }

    // Roles
    function CLAIM_MANAGER() external view returns (bytes32);
    function FEE_MANAGER() external pure returns (bytes32);

    // Access control
    function hasRoleOrOwner(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);

    // Factory
    function feeRecipient() external view returns (address);
    function setFeeRecipient(address _feeRecipient) external;
    function protocolFee() external view returns (uint16);
    function setProtocolFee(uint16 _fee) external;
    function deployMultiPositionManager(PoolKey memory poolKey, address owner, string memory name)
        external
        returns (address);
    function computeAddress(PoolKey memory poolKey, address managerOwner, string memory name)
        external
        view
        returns (address);
    function getManagersByOwner(address managerOwner) external view returns (ManagerInfo[] memory);
    function getAllManagersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (ManagerInfo[] memory managersInfo, uint256 totalCount);
    function getTotalManagersCount() external view returns (uint256);
    function getAllTokenPairsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (TokenPairInfo[] memory pairsInfo, uint256 totalCount);
    function getAllManagersByTokenPair(address currency0, address currency1, uint256 offset, uint256 limit)
        external
        view
        returns (ManagerInfo[] memory managersInfo, uint256 totalCount);

    // Aggregator allowlist
    function aggregatorAddress(uint8 aggregator) external view returns (address);

    // Events
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event MultiPositionManagerDeployed(address indexed multiPositionManager, address indexed owner, PoolKey poolKey);
}
