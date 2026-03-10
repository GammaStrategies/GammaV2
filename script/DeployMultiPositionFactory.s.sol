// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title MultiPositionFactory Deployment Script
 * @notice Deploy a MultiPositionFactory
 *
 * Usage:
 *  forge script script/DeployMultiPositionFactory.s.sol:DeployMultiPositionFactory --rpc-url <network> --broadcast --verify
 *  --sig "run(address,address,address,address,address,address)" <owner> <poolManager> <agg0> <agg1> <agg2> <agg3>
 */
contract DeployMultiPositionFactory is Script {
    /**
     * @notice Deploy factory
     * @param _owner The owner of the factory
     * @param _poolManager The pool manager address
     */
    function run(
        address _owner,
        address _poolManager,
        address agg0,
        address agg1,
        address agg2,
        address agg3
    ) public returns (address factory) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        console.log("Deployment Parameters:");
        console.log("Owner:", _owner);
        console.log("PoolManager:", _poolManager);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the MultiPositionFactory with pool manager
        MultiPositionFactory multiPositionFactory = new MultiPositionFactory(_owner, IPoolManager(_poolManager));
        factory = address(multiPositionFactory);
        console.log("MultiPositionFactory deployed to:", factory);

        if (deployer == _owner) {
            _setAggregators(multiPositionFactory, agg0, agg1, agg2, agg3);
        } else {
            console.log("Note: Deployer is not owner, skipping aggregator configuration");
        }

        vm.stopBroadcast();

        // Log final summary
        console.log("\nDeployment Summary:");
        console.log("--------------------");
        console.log("MultiPositionFactory:", factory);
        console.log("Owner:", _owner);
        console.log("PoolManager:", _poolManager);
        console.log("Initial FeeRecipient:", multiPositionFactory.feeRecipient());

        return factory;
    }

    /**
     * @notice Deploy and configure factory with initial claim managers
     * @param _owner The owner of the factory
     * @param _poolManager The pool manager address
     * @param _claimManagers Initial addresses to grant CLAIM_MANAGER role
     */
    function runWithClaimManagers(
        address _owner,
        address _poolManager,
        address agg0,
        address agg1,
        address agg2,
        address agg3,
        address[] memory _claimManagers
    ) public returns (address factory) {
        factory = run(_owner, _poolManager, agg0, agg1, agg2, agg3);

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Only configure roles if deployer is the owner
        if (vm.addr(deployerPrivateKey) == _owner) {
            vm.startBroadcast(deployerPrivateKey);

            MultiPositionFactory multiPositionFactory = MultiPositionFactory(factory);

            // Grant CLAIM_MANAGER role to specified addresses
            for (uint256 i = 0; i < _claimManagers.length; i++) {
                multiPositionFactory.grantRole(multiPositionFactory.CLAIM_MANAGER(), _claimManagers[i]);
                console.log("Granted CLAIM_MANAGER role to:", _claimManagers[i]);
            }

            vm.stopBroadcast();
        } else {
            console.log("Note: Deployer is not owner, skipping role configuration");
        }

        return factory;
    }

    function _setAggregators(
        MultiPositionFactory factory,
        address agg0,
        address agg1,
        address agg2,
        address agg3
    ) internal {
        if (agg0 != address(0)) factory.setAggregatorAddress(0, agg0);
        if (agg1 != address(0)) factory.setAggregatorAddress(1, agg1);
        if (agg2 != address(0)) factory.setAggregatorAddress(2, agg2);
        if (agg3 != address(0)) factory.setAggregatorAddress(3, agg3);
        console.log("Aggregator allowlist configured");
    }
}
