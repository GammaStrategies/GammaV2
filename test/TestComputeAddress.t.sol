// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

contract TestComputeAddress is Test, Deployers {
    MultiPositionFactory factory;
    PoolKey poolKey;
    address owner = makeAddr("owner");
    address managerOwner = makeAddr("managerOwner");

    function setUp() public {
        // Deploy pool manager (using Deployers helper)
        deployFreshManagerAndRouters();

        // Deploy factory
        factory = new MultiPositionFactory(owner, manager);

        // Setup pool key
        MockERC20 token0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 token1 = new MockERC20("Token1", "TK1", 18);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0) < address(token1) ? address(token0) : address(token1)),
            currency1: Currency.wrap(address(token0) < address(token1) ? address(token1) : address(token0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function test_ComputeAddressMatchesDeployedAddress() public {
        // Get predicted address before deployment
        address predictedAddress = factory.computeAddress(poolKey, managerOwner, "Test LP");

        // Deploy the actual manager
        address deployedAddress = factory.deployMultiPositionManager(poolKey, managerOwner, "Test LP");

        // Verify they match
        assertEq(predictedAddress, deployedAddress, "Computed address should match deployed address");

        // Verify the manager exists at the deployed address
        assertGt(deployedAddress.code.length, 0, "Contract should exist at deployed address");

        // Verify it's actually a MultiPositionManager
        MultiPositionManager manager = MultiPositionManager(payable(deployedAddress));
        assertEq(manager.owner(), managerOwner, "Manager owner should be correct");
    }

    function test_ComputeAddressDeterministic() public {
        // Compute address multiple times with same parameters
        address address1 = factory.computeAddress(poolKey, managerOwner, "Test LP");
        address address2 = factory.computeAddress(poolKey, managerOwner, "Test LP");

        assertEq(address1, address2, "Same parameters should produce same address");

        // Different owner should produce different address
        address differentOwner = makeAddr("differentOwner");
        address address3 = factory.computeAddress(poolKey, differentOwner, "Test LP");

        assertTrue(address1 != address3, "Different parameters should produce different address");

        // Different name should also produce different address
        address address4 = factory.computeAddress(poolKey, managerOwner, "Different LP");
        assertTrue(address1 != address4, "Different name should produce different address");
    }

    function test_SameNameDifferentOwner_ProducesDifferentAddresses() public {
        // Deploy first manager with name "Unique LP"
        address manager1 = factory.deployMultiPositionManager(poolKey, managerOwner, "Unique LP");

        // Deploy second manager with same name but different owner
        // This now works because name uniqueness is not enforced globally
        // Different owner = different salt = different address
        address differentOwner = makeAddr("differentOwner");
        address manager2 = factory.deployMultiPositionManager(poolKey, differentOwner, "Unique LP");

        // Both deployments should succeed with different addresses
        assertGt(manager1.code.length, 0, "Manager 1 should exist");
        assertGt(manager2.code.length, 0, "Manager 2 should exist");
        assertTrue(manager1 != manager2, "Same name with different owners should produce different addresses");
    }

    function test_AllowMultipleManagers_DifferentNames() public {
        // Deploy multiple managers with different names
        address manager1 = factory.deployMultiPositionManager(poolKey, managerOwner, "Manager One");
        address manager2 = factory.deployMultiPositionManager(poolKey, managerOwner, "Manager Two");
        address manager3 = factory.deployMultiPositionManager(poolKey, managerOwner, "Manager Three");

        // Verify all managers were deployed successfully
        assertGt(manager1.code.length, 0, "Manager 1 should exist");
        assertGt(manager2.code.length, 0, "Manager 2 should exist");
        assertGt(manager3.code.length, 0, "Manager 3 should exist");

        // Verify they are different addresses
        assertTrue(manager1 != manager2, "Managers should have different addresses");
        assertTrue(manager2 != manager3, "Managers should have different addresses");
        assertTrue(manager1 != manager3, "Managers should have different addresses");
    }

    function test_CaseSensitiveNames() public {
        // Deploy first manager with lowercase name
        address manager1 = factory.deployMultiPositionManager(poolKey, managerOwner, "test lp");

        // Should be able to deploy with different case (case-sensitive)
        // Different case = different salt = different address
        address manager2 = factory.deployMultiPositionManager(poolKey, managerOwner, "TEST LP");
        assertGt(manager2.code.length, 0, "Manager with different case should deploy successfully");

        // Verify they are different addresses (case-sensitive names)
        assertTrue(manager1 != manager2, "Different case names should produce different addresses");
    }

    function test_DeployMultiPositionManager_Idempotent() public {
        address manager1 = factory.deployMultiPositionManager(poolKey, managerOwner, "Idempotent LP");
        address manager2 = factory.deployMultiPositionManager(poolKey, managerOwner, "Idempotent LP");

        assertEq(manager1, manager2, "Expected same address for duplicate params");
        assertEq(factory.getTotalManagersCount(), 1, "Should not register duplicate manager");

        MultiPositionFactory.ManagerInfo[] memory managers = factory.getManagersByOwner(managerOwner);
        assertEq(managers.length, 1, "Should not add duplicate manager for owner");
    }
}
