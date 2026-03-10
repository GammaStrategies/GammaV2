// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title Deploy Limited Infrastructure
 * @notice Deploys only essential infrastructure: ExponentialStrategy, MultiPositionFactory, and SimpleLens
 * @dev This is a minimal deployment for testing or limited deployments
 *
 * Usage:
 *  forge script script/DeployLimitedInfrastructure.s.sol:DeployLimitedInfrastructure \
 *    --rpc-url <RPC_URL> \
 *    --broadcast \
 *    --verify \
 *    --sig "run(address,address,address,address,address,address)" <owner> <poolManager> <agg0> <agg1> <agg2> <agg3>
 *
 * Example for Unichain:
 *  forge script script/DeployLimitedInfrastructure.s.sol:DeployLimitedInfrastructure \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY" \
 *    --sig "run(address,address,address,address,address,address)" 0xYourAddress 0x1F98400000000000000000000000000000000004 0x0 0x0 0x0 0x0
 */
contract DeployLimitedInfrastructure is Script {
    // Default Unichain pool manager if not provided
    address constant DEFAULT_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    struct DeploymentAddresses {
        address exponentialStrategy;
        address factory;
        address deployer;
        address simpleLens;
    }

    /**
     * @notice Deploy limited infrastructure with custom pool manager
     * @param owner The owner address for the factory
     * @param poolManager The Uniswap V4 pool manager address
     */
    function run(
        address owner,
        address poolManager,
        address agg0,
        address agg1,
        address agg2,
        address agg3
    ) public returns (DeploymentAddresses memory addresses) {
        // Validate inputs
        if (owner == address(0)) revert("Owner cannot be zero address");
        if (poolManager == address(0)) revert("PoolManager cannot be zero address");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying Limited Infrastructure");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Pool Manager:", poolManager);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy ExponentialStrategy
        console.log("Step 1: Deploying ExponentialStrategy...");
        {
            ExponentialStrategy exponentialStrategy = new ExponentialStrategy();
            addresses.exponentialStrategy = address(exponentialStrategy);
            console.log("  ExponentialStrategy:", addresses.exponentialStrategy);
        }

        // Step 2: Deploy MultiPositionFactory (which auto-deploys MultiPositionDeployer)
        console.log("\nStep 2: Deploying MultiPositionFactory...");
        MultiPositionFactory factory;
        {
            factory = new MultiPositionFactory(owner, IPoolManager(poolManager));
            addresses.factory = address(factory);
            addresses.deployer = address(factory.deployer());
            console.log("  MultiPositionFactory:", addresses.factory);
            console.log("  MultiPositionDeployer:", addresses.deployer);
            console.log("  Initial Fee Recipient:", factory.feeRecipient());
            console.log("  Protocol Fee:", factory.protocolFee(), "%");
        }
        if (deployer == owner) {
            _setAggregators(factory, agg0, agg1, agg2, agg3);
        } else {
            console.log("  Note: Deployer is not owner, skipping aggregator configuration");
        }

        // Step 3: Deploy SimpleLens
        console.log("\nStep 3: Deploying SimpleLens...");
        {
            // Deploy SimpleLens with the pool manager
            // Note: SimpleLensInMin and SimpleLensRatioUtils libraries are automatically
            // deployed and linked by the compiler when SimpleLens is deployed
            SimpleLens simpleLens = new SimpleLens(IPoolManager(poolManager));
            addresses.simpleLens = address(simpleLens);
            console.log("  SimpleLens:", addresses.simpleLens);
            console.log("  (Libraries SimpleLensInMin and SimpleLensRatioUtils are auto-deployed)");
        }

        vm.stopBroadcast();

        // Print deployment summary
        _printSummary(addresses, owner, poolManager);

        return addresses;
    }

    /**
     * @notice Deploy with default Unichain pool manager
     * @param owner The owner address for the factory
     */
    function run(address owner) public returns (DeploymentAddresses memory) {
        return run(owner, DEFAULT_POOL_MANAGER, address(0), address(0), address(0), address(0));
    }

    function run(address owner, address poolManager) public returns (DeploymentAddresses memory) {
        return run(owner, poolManager, address(0), address(0), address(0), address(0));
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
        console.log("  Aggregator allowlist configured");
    }

    /**
     * @notice Print deployment summary
     */
    function _printSummary(DeploymentAddresses memory addresses, address owner, address poolManager) private pure {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Configuration:");
        console.log("  Owner:", owner);
        console.log("  Pool Manager:", poolManager);
        console.log("\nStrategy:");
        console.log("  Exponential:", addresses.exponentialStrategy);
        console.log("\nCore Contracts:");
        console.log("  Factory:", addresses.factory);
        console.log("  Deployer:", addresses.deployer);
        console.log("\nLens Contracts:");
        console.log("  SimpleLens:", addresses.simpleLens);
        console.log("========================================\n");

        console.log("Limited infrastructure deployment complete!");
        console.log("You can now deploy MultiPositionManagers using the factory at:", addresses.factory);
        console.log("SimpleLens is available for previewing operations at:", addresses.simpleLens);
        console.log("\nTo deploy a manager, use DeployManager.s.sol or call factory.deployMultiPositionManager()");
    }
}
