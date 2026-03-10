// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {CamelStrategy} from "../src/MultiPositionManager/strategies/CamelStrategy.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {GaussianStrategy} from "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import {UniformStrategy} from "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import {SingleUniformStrategy} from "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";
import {TriangleStrategy} from "../src/MultiPositionManager/strategies/TriangleStrategy.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {InitialDepositLens} from "../src/MultiPositionManager/periphery/InitialDepositLens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title Deploy Infrastructure for Unichain
 * @notice Deploys core infrastructure components needed for the Hypervisor system
 * @dev This includes all strategies, the factory, SimpleLens, InitialDepositLens and supporting libraries
 * @dev RelayerFactory/Deployer are deployed separately via DeployRebalancerInfrastructure.s.sol
 *
 * Usage:
 *  forge script script/DeployInfrastructure.s.sol:DeployInfrastructure \
 *    --rpc-url <UNICHAIN_RPC> \
 *    --broadcast \
 *    --verify \
 *    --sig "run(address,address,address,address,address,address)" <owner> <poolManager> <agg0> <agg1> <agg2> <agg3>
 *
 * Example for Unichain:
 *  forge script script/DeployInfrastructure.s.sol:DeployInfrastructure \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY" \
 *    --sig "run(address,address,address,address,address,address)" 0xYourAddress 0x1F98400000000000000000000000000000000004 0x0 0x0 0x0 0x0
 */
contract DeployInfrastructure is Script {
    // Default Unichain pool manager if not provided
    address constant DEFAULT_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    struct DeploymentAddresses {
        address camelStrategy;
        address exponentialStrategy;
        address gaussianStrategy;
        address uniformStrategy;
        address singleUniformStrategy;
        address triangleStrategy;
        address factory;
        address deployer;
        address simpleLens;
        address initialDepositLens;
    }

    /**
     * @notice Deploy all infrastructure with custom pool manager
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
        require(owner != address(0), "Owner cannot be zero address");
        require(poolManager != address(0), "PoolManager cannot be zero address");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying Infrastructure to Unichain");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Pool Manager:", poolManager);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy all strategy contracts
        console.log("Step 1: Deploying Strategy Contracts...");
        {
            CamelStrategy camelStrategy = new CamelStrategy();
            addresses.camelStrategy = address(camelStrategy);
            console.log("  CamelStrategy:", addresses.camelStrategy);
        }
        {
            ExponentialStrategy exponentialStrategy = new ExponentialStrategy();
            addresses.exponentialStrategy = address(exponentialStrategy);
            console.log("  ExponentialStrategy:", addresses.exponentialStrategy);
        }
        {
            GaussianStrategy gaussianStrategy = new GaussianStrategy();
            addresses.gaussianStrategy = address(gaussianStrategy);
            console.log("  GaussianStrategy:", addresses.gaussianStrategy);
        }
        {
            UniformStrategy uniformStrategy = new UniformStrategy();
            addresses.uniformStrategy = address(uniformStrategy);
            console.log("  UniformStrategy:", addresses.uniformStrategy);
        }
        {
            SingleUniformStrategy singleUniformStrategy = new SingleUniformStrategy();
            addresses.singleUniformStrategy = address(singleUniformStrategy);
            console.log("  SingleUniformStrategy:", addresses.singleUniformStrategy);
        }
        {
            TriangleStrategy triangleStrategy = new TriangleStrategy();
            addresses.triangleStrategy = address(triangleStrategy);
            console.log("  TriangleStrategy:", addresses.triangleStrategy);
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

        // Step 4: Deploy InitialDepositLens
        console.log("\nStep 4: Deploying InitialDepositLens...");
        {
            // Deploy InitialDepositLens with the pool manager
            InitialDepositLens initialDepositLens = new InitialDepositLens(IPoolManager(poolManager));
            addresses.initialDepositLens = address(initialDepositLens);
            console.log("  InitialDepositLens:", addresses.initialDepositLens);
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
        console.log("\nStrategies:");
        console.log("  Camel:", addresses.camelStrategy);
        console.log("  Exponential:", addresses.exponentialStrategy);
        console.log("  Gaussian:", addresses.gaussianStrategy);
        console.log("  Uniform:", addresses.uniformStrategy);
        console.log("  SingleUniform:", addresses.singleUniformStrategy);
        console.log("  Triangle:", addresses.triangleStrategy);
        console.log("\nCore Contracts:");
        console.log("  Factory:", addresses.factory);
        console.log("  Deployer:", addresses.deployer);
        console.log("\nLens Contracts:");
        console.log("  SimpleLens:", addresses.simpleLens);
        console.log("  InitialDepositLens:", addresses.initialDepositLens);
        console.log("========================================\n");

        console.log("Infrastructure deployment complete!");
        console.log("You can now deploy MultiPositionManagers using the factory at:", addresses.factory);
        console.log("SimpleLens is available for previewing operations at:", addresses.simpleLens);
        console.log(
            "InitialDepositLens is available for previewing initial deposits to uninitialized pools at:",
            addresses.initialDepositLens
        );
        console.log("\nTo deploy a manager, use DeployManager.s.sol or call factory.deployMultiPositionManager()");
        console.log("\nTo deploy Rebalancer infrastructure, use DeployRebalancerInfrastructure.s.sol");
    }
}
