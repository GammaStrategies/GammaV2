// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {Multicall} from "../src/MultiPositionManager/base/Multicall.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * @title TestFactoryMulticall
 * @notice Demonstrates using multicall to atomically initialize a pool and deploy a manager
 */
contract TestFactoryMulticall is Test, Deployers {
    MultiPositionFactory factory;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        // Deploy pool manager
        deployFreshManagerAndRouters();

        // Deploy factory
        vm.prank(owner);
        factory = new MultiPositionFactory(owner, manager);

        // Deploy and sort tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();
    }

    /**
     * @notice Test: Multicall to initialize pool and deploy manager atomically
     */
    function test_MulticallInitializeAndDeploy() public {
        // Setup pool key
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});

        // Initial sqrt price: 1:1 ratio
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        // Verify pool doesn't exist yet
        assertFalse(factory.isPoolInitialized(poolKey), "Pool should not be initialized");

        // Prepare multicall data
        bytes[] memory calls = new bytes[](2);

        // Call 1: Initialize pool
        calls[0] = abi.encodeWithSelector(factory.initializePoolIfNeeded.selector, poolKey, sqrtPriceX96);

        // Call 2: Deploy MultiPositionManager
        calls[1] =
            abi.encodeWithSelector(factory.deployMultiPositionManager.selector, poolKey, alice, "My Liquidity Position");

        // Execute multicall
        bytes[] memory results = factory.multicall(calls);

        // Verify pool was initialized
        assertTrue(factory.isPoolInitialized(poolKey), "Pool should be initialized");

        // Decode results
        int24 tick = abi.decode(results[0], (int24));
        address mpmAddress = abi.decode(results[1], (address));

        // Verify tick is reasonable
        assertGt(tick, -887272, "Tick should be valid");
        assertLt(tick, 887272, "Tick should be valid");

        // Verify manager was deployed
        assertTrue(mpmAddress != address(0), "Manager should be deployed");

        // Verify manager info is stored
        (address storedAddress, address storedOwner,, string memory storedName) = factory.managers(mpmAddress);
        assertEq(storedAddress, mpmAddress, "Manager address should match");
        assertEq(storedOwner, alice, "Manager owner should match");
        assertEq(storedName, "My Liquidity Position", "Manager name should match");
    }

    /**
     * @notice Test: Pool already initialized - multicall still works
     */
    function test_MulticallWithExistingPool() public {
        // Setup pool key
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});

        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        // Initialize pool directly first
        manager.initialize(poolKey, sqrtPriceX96);
        assertTrue(factory.isPoolInitialized(poolKey), "Pool should be initialized");

        // Now try multicall (should not revert)
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(factory.initializePoolIfNeeded.selector, poolKey, sqrtPriceX96);

        calls[1] =
            abi.encodeWithSelector(factory.deployMultiPositionManager.selector, poolKey, alice, "Second Position");

        // Should not revert even though pool exists
        bytes[] memory results = factory.multicall(calls);

        address mpmAddress = abi.decode(results[1], (address));
        assertTrue(mpmAddress != address(0), "Manager should be deployed");
    }
}
