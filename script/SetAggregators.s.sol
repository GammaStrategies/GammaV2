// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";

/**
 * @title Set Aggregator Allowlist
 * @notice Configure the MultiPositionFactory swap aggregator allowlist
 *
 * Aggregator enum mapping (from RebalanceLogic):
 *  0 = ZERO_X
 *  1 = KYBERSWAP
 *  2 = ODOS
 *  3 = PARASWAP
 *
 * Usage:
 *  forge script script/SetAggregators.s.sol:SetAggregators \
 *    --rpc-url <network> \
 *    --broadcast \
 *    --slow \
 *    --sig "run(address,address,address,address,address)" <factory> <agg0> <agg1> <agg2> <agg3>
 *
 * Recommended (strict preflight):
 *  forge script script/SetAggregators.s.sol:SetAggregators \
 *    --rpc-url <network> \
 *    --broadcast \
 *    --slow \
 *    --sig "runWithExpectations(address,address,address,address,address,uint256,address)" \
 *    <factory> <agg0> <agg1> <agg2> <agg3> <expectedChainId> <expectedOwner>
 */
contract SetAggregators is Script {
    function run(
        address factoryAddress,
        address agg0,
        address agg1,
        address agg2,
        address agg3
    ) public {
        _run(factoryAddress, agg0, agg1, agg2, agg3, block.chainid, address(0));
    }

    function runWithExpectations(
        address factoryAddress,
        address agg0,
        address agg1,
        address agg2,
        address agg3,
        uint256 expectedChainId,
        address expectedOwner
    ) public {
        _run(factoryAddress, agg0, agg1, agg2, agg3, expectedChainId, expectedOwner);
    }

    function runSingle(address factoryAddress, uint8 slot, address router) public {
        require(slot <= 3, "Invalid aggregator slot");
        require(router != address(0), "Router cannot be zero");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        MultiPositionFactory factory = MultiPositionFactory(factoryAddress);
        address owner = factory.owner();

        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddress);
        console.log("Owner:", owner);
        console.log("Setting slot:", slot);
        console.log("Router:", router);

        require(deployer == owner, "Deployer is not factory owner");

        vm.startBroadcast(deployerPrivateKey);
        factory.setAggregatorAddress(slot, router);
        vm.stopBroadcast();

        require(factory.aggregatorAddress(slot) == router, "Slot write verification failed");
        console.log("Verified slot", slot, ":", factory.aggregatorAddress(slot));
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
    }

    function _run(
        address factoryAddress,
        address agg0,
        address agg1,
        address agg2,
        address agg3,
        uint256 expectedChainId,
        address expectedOwner
    ) internal {
        require(factoryAddress != address(0), "Factory cannot be zero");
        require(agg0 != address(0) || agg1 != address(0) || agg2 != address(0) || agg3 != address(0), "No updates");
        require(block.chainid == expectedChainId, "Unexpected chain");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        MultiPositionFactory factory = MultiPositionFactory(factoryAddress);
        address owner = factory.owner();

        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Factory:", factoryAddress);
        console.log("Owner:", owner);

        if (expectedOwner != address(0)) {
            require(owner == expectedOwner, "Factory owner mismatch");
        }
        require(deployer == owner, "Deployer is not factory owner");

        vm.startBroadcast(deployerPrivateKey);
        _setAggregators(factory, agg0, agg1, agg2, agg3);
        vm.stopBroadcast();

        _verify(factory, agg0, agg1, agg2, agg3);
    }

    function _verify(MultiPositionFactory factory, address agg0, address agg1, address agg2, address agg3) internal view {
        if (agg0 != address(0)) require(factory.aggregatorAddress(0) == agg0, "Slot 0 verification failed");
        if (agg1 != address(0)) require(factory.aggregatorAddress(1) == agg1, "Slot 1 verification failed");
        if (agg2 != address(0)) require(factory.aggregatorAddress(2) == agg2, "Slot 2 verification failed");
        if (agg3 != address(0)) require(factory.aggregatorAddress(3) == agg3, "Slot 3 verification failed");

        console.log("Aggregator allowlist:");
        console.log("0 (ZERO_X):", factory.aggregatorAddress(0));
        console.log("1 (KYBERSWAP):", factory.aggregatorAddress(1));
        console.log("2 (ODOS):", factory.aggregatorAddress(2));
        console.log("3 (PARASWAP):", factory.aggregatorAddress(3));
    }
}
