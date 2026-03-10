// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MultiPositionManager} from "./MultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title MultiPositionDeployer
 * @notice Deploys MultiPositionManager contracts with CREATE2
 * @dev Separated from factory to reduce factory contract size
 */
contract MultiPositionDeployer {
    /// @notice The authorized factory that can call deploy
    address public immutable authorizedFactory;

    /// @notice Error when caller is not the authorized factory
    error UnauthorizedCaller();

    constructor(address _authorizedFactory) {
        authorizedFactory = _authorizedFactory;
    }
    /**
     * @notice Deploys a new MultiPositionManager contract
     * @param poolManager The Uniswap V4 pool manager
     * @param poolKey The pool key for the Uniswap V4 pool
     * @param owner The owner of the new MultiPositionManager
     * @param factory The factory contract address
     * @param name The name of the LP token
     * @param symbol The symbol of the LP token
     * @param fee The protocol fee
     * @param salt The salt for CREATE2 deployment
     * @return The address of the deployed MultiPositionManager
     */
    function deploy(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        address owner,
        address factory,
        string memory name,
        string memory symbol,
        uint16 fee,
        bytes32 salt
    ) external returns (address) {
        if (msg.sender != authorizedFactory) revert UnauthorizedCaller();
        return address(new MultiPositionManager{salt: salt}(poolManager, poolKey, owner, factory, name, symbol, fee));
    }

    /**
     * @notice Computes the address where a MultiPositionManager will be deployed
     * @param poolManager The Uniswap V4 pool manager
     * @param poolKey The pool key for the Uniswap V4 pool
     * @param owner The owner of the new MultiPositionManager
     * @param factory The factory contract address
     * @param name The name of the LP token
     * @param symbol The symbol of the LP token
     * @param fee The protocol fee
     * @param salt The salt for CREATE2 deployment
     * @return predicted The address where the MultiPositionManager will be deployed
     */
    function computeAddress(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        address owner,
        address factory,
        string memory name,
        string memory symbol,
        uint16 fee,
        bytes32 salt
    ) external view returns (address predicted) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                type(MultiPositionManager).creationCode,
                abi.encode(poolManager, poolKey, owner, factory, name, symbol, fee)
            )
        );

        /// @solidity memory-safe-assembly
        assembly {
            // Load free memory pointer
            let ptr := mload(0x40)

            // Store 0xff at the correct position (byte 0 of our 85-byte data)
            mstore(ptr, 0xff00000000000000000000000000000000000000000000000000000000000000)

            // Store address at byte 1 (shift right by 96 bits = 12 bytes to right-align in 20 bytes)
            mstore(add(ptr, 0x01), shl(96, address()))

            // Store salt at byte 21
            mstore(add(ptr, 0x15), salt)

            // Store hash at byte 53
            mstore(add(ptr, 0x35), hash)

            // Hash 85 bytes starting from ptr
            predicted := keccak256(ptr, 0x55)
        }
    }
}
