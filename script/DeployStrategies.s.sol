// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CamelStrategy} from "../src/MultiPositionManager/strategies/CamelStrategy.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {GaussianStrategy} from "../src/MultiPositionManager/strategies/GaussianStrategy.sol";
import {UniformStrategy} from "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import {SingleUniformStrategy} from "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";
import {TriangleStrategy} from "../src/MultiPositionManager/strategies/TriangleStrategy.sol";

/**
 * @title Deploy All Strategies
 * @notice Deploys all liquidity distribution strategy contracts
 * @dev Strategies are stateless contracts that can be shared across all MultiPositionManagers
 *
 * Usage:
 *  forge script script/DeployStrategies.s.sol:DeployStrategies \
 *    --rpc-url <RPC_URL> \
 *    --broadcast \
 *    --verify
 *
 * Example for Unichain:
 *  forge script script/DeployStrategies.s.sol:DeployStrategies \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY"
 */
contract DeployStrategies is Script {
    struct StrategyAddresses {
        address camelStrategy;
        address exponentialStrategy;
        address gaussianStrategy;
        address uniformStrategy;
        address singleUniformStrategy;
        address triangleStrategy;
    }

    /**
     * @notice Deploy all strategy contracts
     * @return addresses Struct containing all deployed strategy addresses
     */
    function run() public returns (StrategyAddresses memory addresses) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying All Strategies");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy all strategy contracts
        console.log("Deploying Strategy Contracts...\n");

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

        vm.stopBroadcast();

        // Print deployment summary
        _printSummary(addresses, deployer);

        return addresses;
    }

    /**
     * @notice Print deployment summary
     */
    function _printSummary(StrategyAddresses memory addresses, address deployer) private pure {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("\nStrategies:");
        console.log("  Camel:", addresses.camelStrategy);
        console.log("  Exponential:", addresses.exponentialStrategy);
        console.log("  Gaussian:", addresses.gaussianStrategy);
        console.log("  Uniform:", addresses.uniformStrategy);
        console.log("  SingleUniform:", addresses.singleUniformStrategy);
        console.log("  Triangle:", addresses.triangleStrategy);
        console.log("========================================\n");

        console.log("Strategy deployment complete!");
        console.log("\nStrategy Descriptions:");
        console.log("  - Camel: Double-peaked distribution for bimodal price behavior");
        console.log("  - Exponential: Exponential decay from center for concentrated liquidity");
        console.log("  - Gaussian: Bell curve distribution centered on current price");
        console.log("  - Uniform: Equal liquidity across all positions");
        console.log("  - SingleUniform: Single wide position (gas efficient)");
        console.log("  - Triangle: Linear decay from center (pyramid shape)");
        console.log("\nNext Steps:");
        console.log("  1. Use these strategy addresses when calling rebalance() on MultiPositionManagers");
        console.log("  2. Pass the desired strategy address to the rebalance params");
    }
}
