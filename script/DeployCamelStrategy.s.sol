// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CamelStrategy} from "../src/MultiPositionManager/strategies/CamelStrategy.sol";

/**
 * @title Deploy CamelStrategy
 * @notice Deploys the CamelStrategy contract as a standalone deployment
 * @dev CamelStrategy implements a double-peaked (camel) liquidity distribution pattern
 *      that concentrates liquidity around two price points, useful for assets with
 *      bimodal price behavior or for providing liquidity at multiple support/resistance levels.
 *
 * Usage:
 *  forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy \
 *    --rpc-url <RPC_URL> \
 *    --broadcast \
 *    --verify
 *
 * Example for Unichain:
 *  forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --verify
 *
 * Example for local testing:
 *  forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy
 */
contract DeployCamelStrategy is Script {
    /**
     * @notice Deploy CamelStrategy contract
     * @return camelStrategy The deployed CamelStrategy address
     */
    function run() public returns (address camelStrategy) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying CamelStrategy");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy CamelStrategy
        CamelStrategy strategy = new CamelStrategy();
        camelStrategy = address(strategy);

        vm.stopBroadcast();

        // Print deployment summary
        _printSummary(camelStrategy, deployer);

        return camelStrategy;
    }

    /**
     * @notice Print deployment summary
     */
    function _printSummary(address camelStrategy, address deployer) private pure {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("CamelStrategy:", camelStrategy);
        console.log("========================================\n");

        console.log("CamelStrategy deployment complete!");
        console.log("\nStrategy Details:");
        console.log("  - Type: Camel (Double-peaked distribution)");
        console.log("  - Use Case: Bimodal price distributions");
        console.log("  - Features: Two concentration peaks with flexible positioning");
        console.log("\nNext Steps:");
        console.log("  1. Use this strategy address when creating MultiPositionManagers");
        console.log("  2. Pass it to factory.deployMultiPositionManager() as the strategy parameter");
        console.log("  3. Configure peak positions and spread based on your liquidity needs");
    }
}
