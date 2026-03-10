// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {InitialDepositLens} from "../src/MultiPositionManager/periphery/InitialDepositLens.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title Deploy InitialDepositLens
 * @notice Deploys only the InitialDepositLens contract with its libraries
 * @dev InitialDepositLens is used for previewing initial deposits to UNINITIALIZED pools
 *
 * Usage:
 *  forge script script/DeployInitialDepositLens.s.sol:DeployInitialDepositLens \
 *    --sig "run(address)" <POOL_MANAGER_ADDRESS> \
 *    --rpc-url https://0xrpc.io/uni \
 *    --broadcast \
 *    --verify \
 *    --verifier-url "https://api.etherscan.io/v2/api?chainId=<CHAIN_ID>" \
 *    --etherscan-api-key "YOUR_API_KEY"
 *
 * Example:
 *  forge script script/DeployInitialDepositLens.s.sol:DeployInitialDepositLens \
 *    --sig "run(address)" 0x000000000004444c5dc75cB358380D2e3dE08A90 \
 *    --rpc-url https://0xrpc.io/uni \
 *    --broadcast
 */
contract DeployInitialDepositLens is Script {
    function run(address poolManager) public returns (address initialDepositLensAddress) {
        if (poolManager == address(0)) revert("PoolManager address cannot be zero");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying InitialDepositLens");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Pool Manager:", poolManager);
        console.log("========================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy InitialDepositLens
        // Note: SimpleLensInMin and SimpleLensRatioUtils libraries are automatically
        // deployed and linked by the compiler when InitialDepositLens is deployed
        InitialDepositLens initialDepositLens = new InitialDepositLens(IPoolManager(poolManager));
        initialDepositLensAddress = address(initialDepositLens);

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("InitialDepositLens:", initialDepositLensAddress);
        console.log("Pool Manager:", poolManager);
        console.log("(Libraries SimpleLensInMin and SimpleLensRatioUtils auto-deployed)");
        console.log("========================================\n");

        return initialDepositLensAddress;
    }
}
