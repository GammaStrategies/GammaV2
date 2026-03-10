// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRelayerFactory} from "../src/MultiPositionManager/interfaces/IRelayerFactory.sol";

/**
 * @title SetRelayerMinBalance
 * @notice Sets RelayerFactory minBalance (owner only)
 * @dev Uses DEPLOYER_PRIVATE_KEY
 *
 * Usage:
 * forge script script/SetRelayerMinBalance.s.sol:SetRelayerMinBalance \
 *   --rpc-url <RPC_URL> \
 *   --broadcast \
 *   --sig "run(address,uint256)" \
 *   <relayerFactory> <newMinBalanceWei>
 */
contract SetRelayerMinBalance is Script {
    error ZeroAddress();
    error NoCodeAtAddress(address target);

    function run(address relayerFactory, uint256 newMinBalanceWei) external {
        if (relayerFactory == address(0)) revert ZeroAddress();
        if (relayerFactory.code.length == 0) revert NoCodeAtAddress(relayerFactory);

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address signer = vm.addr(deployerPrivateKey);

        IRelayerFactory factory = IRelayerFactory(relayerFactory);
        uint256 oldMinBalance = factory.minBalance();

        console.log("RelayerFactory:", relayerFactory);
        console.log("Signer:", signer);
        console.log("Current minBalance:", oldMinBalance);
        console.log("New minBalance:", newMinBalanceWei);

        vm.startBroadcast(deployerPrivateKey);
        factory.setMinBalance(newMinBalanceWei);
        vm.stopBroadcast();

        uint256 updatedMinBalance = factory.minBalance();
        console.log("Updated minBalance:", updatedMinBalance);
    }
}
