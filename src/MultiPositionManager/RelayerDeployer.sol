// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Relayer} from "./Relayer.sol";
import {IRelayer} from "./interfaces/IRelayer.sol";

/**
 * @title RelayerDeployer
 * @notice Deploys Relayer contracts using CREATE2 for deterministic addresses
 * @dev Separated from factory to reduce factory contract size
 */
contract RelayerDeployer {
    /// @notice The authorized factory that can call deploy
    address public immutable authorizedFactory;

    /// @notice Error when caller is not the authorized factory
    error UnauthorizedCaller();

    constructor(address _authorizedFactory) {
        authorizedFactory = _authorizedFactory;
    }
    /**
     * @notice Deploys a new Relayer contract using CREATE2
     * @param mpm The MultiPositionManager to automate
     * @param factory The factory contract address
     * @param owner The owner of the new Relayer
     * @param triggerConfig Initial trigger configuration
     * @param strategyParams Initial strategy parameters
     * @param volatilityParams Volatility parameters for this token pair
     * @param withdrawalParams Initial withdrawal trigger parameters
     * @param compoundSwapParams Initial compound swap trigger parameters
     * @param twapParams TWAP-based protection and centering parameters
     * @return The address of the deployed Relayer
     * @dev Uses CREATE2 with salt = keccak256(abi.encodePacked(mpm, owner))
     */
    function deploy(
        address mpm,
        address factory,
        address owner,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external returns (address) {
        if (msg.sender != authorizedFactory) revert UnauthorizedCaller();
        bytes32 salt = keccak256(abi.encodePacked(mpm, owner));
        return address(
            new Relayer{salt: salt}(
                mpm,
                factory,
                owner,
                triggerConfig,
                strategyParams,
                volatilityParams,
                withdrawalParams,
                compoundSwapParams,
                twapParams
            )
        );
    }

    /**
     * @notice Computes the address where a Relayer will be deployed
     * @param mpm The MultiPositionManager to automate
     * @param factory The factory contract address
     * @param owner The owner of the new Relayer
     * @param triggerConfig Initial trigger configuration
     * @param strategyParams Initial strategy parameters
     * @param volatilityParams Volatility parameters for this token pair
     * @param withdrawalParams Initial withdrawal trigger parameters
     * @param compoundSwapParams Initial compound swap trigger parameters
     * @param twapParams TWAP-based protection and centering parameters
     * @return predicted The predicted address of the Relayer
     * @dev Uses CREATE2 address computation
     */
    function computeAddress(
        address mpm,
        address factory,
        address owner,
        IRelayer.TriggerConfig calldata triggerConfig,
        IRelayer.StrategyParams calldata strategyParams,
        IRelayer.VolatilityParams calldata volatilityParams,
        IRelayer.WithdrawalParams calldata withdrawalParams,
        IRelayer.CompoundSwapParams calldata compoundSwapParams,
        IRelayer.TwapParams calldata twapParams
    ) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(mpm, owner));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(Relayer).creationCode,
                abi.encode(
                    mpm,
                    factory,
                    owner,
                    triggerConfig,
                    strategyParams,
                    volatilityParams,
                    withdrawalParams,
                    compoundSwapParams,
                    twapParams
                )
            )
        );

        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
