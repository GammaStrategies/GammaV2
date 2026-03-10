// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RelayerFactory} from "../src/MultiPositionManager/RelayerFactory.sol";
import {IMultiPositionFactory} from "../src/MultiPositionManager/interfaces/IMultiPositionFactory.sol";

/**
 * @title Deploy Rebalancer Infrastructure
 * @notice Deploys RelayerFactory and RelayerDeployer
 * @dev Separated from main infrastructure deployment to allow independent updates
 *
 * Usage:
 *  forge script script/DeployRebalancerInfrastructure.s.sol:DeployRebalancerInfrastructure \
 *    --rpc-url <RPC_URL> \
 *    --broadcast \
 *    --verify \
 *    --sig "run(address,address)" <owner> <multiPositionFactory>
 *
 * Example for Unichain:
 *  forge script script/DeployRebalancerInfrastructure.s.sol:DeployRebalancerInfrastructure \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY" \
 *    --sig "run(address,address)" 0xYourAddress 0xMultiPositionFactoryAddress
 */
contract DeployRelayerInfrastructure is Script {
    struct DeploymentAddresses {
        address rebalancerFactory;
        address rebalancerDeployer;
    }

    /**
     * @notice Deploy Rebalancer infrastructure
     * @param owner The owner address for the RelayerFactory
     * @param multiPositionFactory The MultiPositionFactory address
     */
    function run(address owner, address multiPositionFactory) public returns (DeploymentAddresses memory addresses) {
        // Validate inputs
        require(owner != address(0), "Owner cannot be zero address");
        require(multiPositionFactory != address(0), "MultiPositionFactory cannot be zero address");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying Rebalancer Infrastructure");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("MultiPositionFactory:", multiPositionFactory);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy RelayerFactory
        console.log("Step 1: Deploying RelayerFactory...");
        RelayerFactory rebalancerFactory = new RelayerFactory(owner, IMultiPositionFactory(multiPositionFactory));
        addresses.rebalancerFactory = address(rebalancerFactory);
        addresses.rebalancerDeployer = address(rebalancerFactory.deployer());
        console.log("  RelayerFactory:", addresses.rebalancerFactory);
        console.log("  RelayerDeployer:", addresses.rebalancerDeployer);

        // Grant FEE_MANAGER role to RelayerFactory on MultiPositionFactory
        // This allows RelayerFactory to set automated management fees on deployed MultiPositionManagers
        IMultiPositionFactory factory = IMultiPositionFactory(multiPositionFactory);
        factory.grantRole(factory.FEE_MANAGER(), address(rebalancerFactory));
        console.log("  Granted FEE_MANAGER role to RelayerFactory");

        vm.stopBroadcast();

        // Print deployment summary
        _printSummary(addresses, owner, multiPositionFactory);

        return addresses;
    }

    /**
     * @notice Print deployment summary
     */
    function _printSummary(DeploymentAddresses memory addresses, address owner, address multiPositionFactory)
        private
        pure
    {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Configuration:");
        console.log("  Owner:", owner);
        console.log("  MultiPositionFactory:", multiPositionFactory);
        console.log("\nAutomation Contracts:");
        console.log("  RelayerFactory:", addresses.rebalancerFactory);
        console.log("  RelayerDeployer:", addresses.rebalancerDeployer);
        console.log("========================================\n");

        console.log("Rebalancer infrastructure deployment complete!");
        console.log("RelayerFactory is available for deploying automated rebalancers at:", addresses.rebalancerFactory);
        console.log("\nTo deploy a rebalancer, call RelayerFactory.deployRebalancer() or use your deployment script");
    }
}
