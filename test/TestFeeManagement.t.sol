// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestFeeManagement is Test, Deployers {
    using CurrencyLibrary for Currency;

    MultiPositionFactory factory;
    MultiPositionManager manager1;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;

    address factoryOwner = makeAddr("factoryOwner");
    address managerOwner = makeAddr("managerOwner");
    address alice = makeAddr("alice");

    uint160 constant INITIAL_PRICE_SQRT = 79228162514264337593543950336; // 1:1 price
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    function setUp() public {
        // Deploy v4 core
        deployFreshManagerAndRouters();

        // Deploy tokens
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize pool
        manager.initialize(poolKey, INITIAL_PRICE_SQRT);

        // Deploy factory with factoryOwner
        factory = new MultiPositionFactory(factoryOwner, manager);

        // Grant FEE_MANAGER role to factoryOwner so they can set fees on managers
        bytes32 feeManagerRole = factory.FEE_MANAGER();
        vm.prank(factoryOwner);
        factory.grantRole(feeManagerRole, factoryOwner);
    }

    function test_FactoryOwnerCanSetProtocolFee() public {
        // Check initial fee
        assertEq(factory.protocolFee(), 10);

        // Factory owner sets new fee
        vm.prank(factoryOwner);
        factory.setProtocolFee(30);

        assertEq(factory.protocolFee(), 30);
    }

    function test_NonFactoryOwnerCannotSetProtocolFee() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.setProtocolFee(20);
    }

    function test_NewManagerGetsFactoryFee() public {
        // Set factory fee to 25
        vm.prank(factoryOwner);
        factory.setProtocolFee(25);

        // Deploy a new manager
        address newManager = factory.deployMultiPositionManager(poolKey, managerOwner, "Test MPM");

        MultiPositionManager mpm = MultiPositionManager(payable(newManager));

        // Check that the manager has the factory's fee
        assertEq(mpm.fee(), 25);
    }

    function test_OnlyFactoryOwnerCanSetManagerFee() public {
        // Deploy a manager
        address newManager = factory.deployMultiPositionManager(poolKey, managerOwner, "Test MPM");

        MultiPositionManager mpm = MultiPositionManager(payable(newManager));

        // Manager owner cannot set fee
        vm.expectRevert();
        vm.prank(managerOwner);
        mpm.setFee(25);

        // Random user cannot set fee
        vm.expectRevert();
        vm.prank(alice);
        mpm.setFee(25);

        // Factory owner CAN set fee
        vm.prank(factoryOwner);
        mpm.setFee(25);

        assertEq(mpm.fee(), 25);
    }

    function test_FactoryOwnerCanUpdateMultipleManagersFees() public {
        // Deploy multiple managers
        address manager1Addr = factory.deployMultiPositionManager(poolKey, managerOwner, "MPM1");
        address manager2Addr = factory.deployMultiPositionManager(poolKey, alice, "MPM2");

        MultiPositionManager mpm1 = MultiPositionManager(payable(manager1Addr));
        MultiPositionManager mpm2 = MultiPositionManager(payable(manager2Addr));

        // Both should start with the default fee
        assertEq(mpm1.fee(), 10);
        assertEq(mpm2.fee(), 10);

        // Factory owner updates fees individually
        vm.startPrank(factoryOwner);
        mpm1.setFee(25);
        mpm2.setFee(30);
        vm.stopPrank();

        assertEq(mpm1.fee(), 25);
        assertEq(mpm2.fee(), 30);
    }

    function test_ChangingFactoryFeeDoesNotAffectExistingManagers() public {
        // Deploy a manager with fee 10 (default)
        address managerAddr = factory.deployMultiPositionManager(poolKey, managerOwner, "Test MPM");
        MultiPositionManager mpm = MultiPositionManager(payable(managerAddr));
        assertEq(mpm.fee(), 10);

        // Change factory fee
        vm.prank(factoryOwner);
        factory.setProtocolFee(35);

        // Existing manager fee unchanged
        assertEq(mpm.fee(), 10);

        // New manager gets new fee
        address newManagerAddr = factory.deployMultiPositionManager(poolKey, alice, "New MPM");
        MultiPositionManager newMpm = MultiPositionManager(payable(newManagerAddr));
        assertEq(newMpm.fee(), 35);
    }
}
