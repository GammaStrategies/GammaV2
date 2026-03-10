// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";

/// @title SharedStructs
/// @notice Contains structs shared between the main contract and libraries
library SharedStructs {
    /// @notice The complete storage of MultiPositionManager
    /// @dev Consolidated into a single struct following Bunni's pattern
    struct ManagerStorage {
        // Pool configuration
        PoolKey poolKey;
        PoolId poolId;
        Currency currency0;
        Currency currency1;
        // Positions
        mapping(uint256 => IMultiPositionManager.Range) basePositions;
        uint256 basePositionsLength;
        IMultiPositionManager.Range[2] limitPositions;
        uint256 limitPositionsLength;
        // External contracts
        address factory;
        // Fees
        uint16 fee;
        // Role management
        mapping(address => bool) relayers;
        // Strategy parameters - efficiently packed
        StrategyParams lastStrategyParams;
    }

    /// @notice Last used strategy parameters
    /// @dev Packed across 3 storage slots (bool flags spill into a third slot)
    struct StrategyParams {
        address strategy; // 20 bytes
        int24 centerTick; // 3 bytes
        uint24 ticksLeft; // 3 bytes
        uint24 ticksRight; // 3 bytes
        uint24 limitWidth; // 3 bytes
        // Total: 32 bytes - fills slot 1
        uint120 weight0; // 15 bytes (enough for 1e18 precision)
        uint120 weight1; // 15 bytes
        bool useCarpet; // 1 byte (full-range floor flag)
        bool useSwap; // 1 byte
        bool useAssetWeights; // 1 byte
            // Total: 32 bytes - fills slot 2 efficiently
    }

    /// @notice Environment variables passed to libraries
    /// @dev Contains immutable values and frequently accessed contracts
    struct Env {
        address poolManager;
        uint16 protocolFee;
    }
}
