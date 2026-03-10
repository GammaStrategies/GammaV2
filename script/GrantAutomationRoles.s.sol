// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IRelayerFactoryGrant {
    function owner() external view returns (address);
    function multiPositionFactory() external view returns (address);
    function AUTOMATION_SERVICE_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
}

interface IMultiPositionFactoryRoles {
    function CLAIM_MANAGER() external view returns (bytes32);
    function FEE_MANAGER() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * @title GrantAutomationRoles
 * @notice Grants RelayerFactory AUTOMATION_SERVICE_ROLE to automation executors
 * @dev Uses DEPLOYER_PRIVATE_KEY, so signer must be RelayerFactory owner
 *
 * Usage:
 * forge script script/GrantAutomationRoles.s.sol:GrantAutomationRoles \
 *   --rpc-url <RPC_URL> \
 *   --broadcast \
 *   --sig "run(address,address,address,address)" \
 *   <relayerFactory> <executor1> <executor2> <executor3>
 */
contract GrantAutomationRoles is Script {
    error ZeroAddress();

    function run(address relayerFactory, address executor1, address executor2, address executor3) external {
        if (relayerFactory == address(0) || executor1 == address(0) || executor2 == address(0) || executor3 == address(0))
        {
            revert ZeroAddress();
        }

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address signer = vm.addr(deployerPrivateKey);

        IRelayerFactoryGrant factory = IRelayerFactoryGrant(relayerFactory);
        address mpmFactory = factory.multiPositionFactory();
        bytes32 automationRole = factory.AUTOMATION_SERVICE_ROLE();

        console.log("RelayerFactory:", relayerFactory);
        console.log("Signer:", signer);
        console.log("Factory owner:", factory.owner());
        console.log("MultiPositionFactory:", mpmFactory);
        console.logBytes32(automationRole);

        address[] memory executors = new address[](3);
        executors[0] = executor1;
        executors[1] = executor2;
        executors[2] = executor3;

        vm.startBroadcast(deployerPrivateKey);

        for (uint256 i = 0; i < executors.length; i++) {
            bool hasAutomation = factory.hasRole(automationRole, executors[i]);
            if (hasAutomation) {
                console.log("AUTOMATION_SERVICE_ROLE already granted:", executors[i]);
            } else {
                factory.grantRole(automationRole, executors[i]);
                console.log("AUTOMATION_SERVICE_ROLE granted:", executors[i]);
            }
        }

        vm.stopBroadcast();

        // Visibility only: MultiPositionFactory has CLAIM_MANAGER / FEE_MANAGER roles (no relayer/automation role).
        IMultiPositionFactoryRoles mpm = IMultiPositionFactoryRoles(mpmFactory);
        bytes32 claimRole = mpm.CLAIM_MANAGER();
        bytes32 feeRole = mpm.FEE_MANAGER();

        for (uint256 i = 0; i < executors.length; i++) {
            bool hasClaimRole = mpm.hasRole(claimRole, executors[i]);
            bool hasFeeRole = mpm.hasRole(feeRole, executors[i]);
            console.log("MPM role state for executor:", executors[i]);
            console.log("  CLAIM_MANAGER:", hasClaimRole);
            console.log("  FEE_MANAGER:", hasFeeRole);
        }
    }
}
