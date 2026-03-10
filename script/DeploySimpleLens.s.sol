// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title Deploy SimpleLens
 * @notice Deploys only the SimpleLens contract with its libraries
 *
 * Usage:
 *  forge script script/DeploySimpleLens.s.sol:DeploySimpleLens \
 *    --sig "run(address)" <POOL_MANAGER_ADDRESS> \
 *    --rpc-url https://0xrpc.io/uni \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY"
 *
 * Example:
 *  forge script script/DeploySimpleLens.s.sol:DeploySimpleLens \
 *    --sig "run(address)" 0x000000000004444c5dc75cB358380D2e3dE08A90 \
 *    --rpc-url https://0xrpc.io/uni \
 *    --broadcast
 */
contract DeploySimpleLens is Script {
    function run(address poolManager) public returns (address simpleLensAddress) {
        if (poolManager == address(0)) revert("PoolManager address cannot be zero");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying SimpleLens");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Pool Manager:", poolManager);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SimpleLens
        // Note: SimpleLensInMin and SimpleLensRatioUtils libraries are automatically
        // deployed and linked by the compiler when SimpleLens is deployed
        SimpleLens simpleLens = new SimpleLens(IPoolManager(poolManager));
        simpleLensAddress = address(simpleLens);

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("SimpleLens:", simpleLensAddress);
        console.log("Pool Manager:", poolManager);
        console.log("(Libraries SimpleLensInMin and SimpleLensRatioUtils auto-deployed)");
        console.log("========================================\n");

        return simpleLensAddress;
    }
}
