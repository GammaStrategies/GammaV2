// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MultiPositionFactory} from "../../src/MultiPositionManager/MultiPositionFactory.sol";
import {UniformStrategy} from "../../src/MultiPositionManager/strategies/UniformStrategy.sol";
import {InitialDepositLens} from "../../src/MultiPositionManager/periphery/InitialDepositLens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title MultiPositionFactoryDeployer
 * @notice Helper library for deploying MultiPositionFactory and related contracts in tests
 */
library MultiPositionFactoryDeployer {
    struct DeploymentResult {
        MultiPositionFactory factory;
        UniformStrategy uniformStrategy;
        InitialDepositLens initialDepositLens;
    }

    /**
     * @notice Deploy MultiPositionFactory with all dependencies
     * @param owner Owner of the factory
     * @param poolManager PoolManager instance
     * @return result Struct containing deployed contracts
     */
    function deploy(
        address owner,
        IPoolManager poolManager
    ) internal returns (DeploymentResult memory result) {
        // Deploy MultiPositionFactory
        result.factory = new MultiPositionFactory(owner, poolManager);

        // Deploy UniformStrategy (no constructor args)
        result.uniformStrategy = new UniformStrategy();

        // Deploy InitialDepositLens
        result.initialDepositLens = new InitialDepositLens(poolManager);

        return result;
    }
}
