// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";

contract TestRebalancerRole is Test, Deployers {
    using CurrencyLibrary for Currency;

    MultiPositionFactory factory;
    MultiPositionManager mpm;
    ExponentialStrategy strategy;
    SimpleLens lens;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;

    address factoryOwner = makeAddr("factoryOwner");
    address managerOwner = makeAddr("managerOwner");
    address relayer1 = makeAddr("rebalancer1");
    address relayer2 = makeAddr("rebalancer2");
    address alice = makeAddr("alice");

    uint160 constant INITIAL_PRICE_SQRT = 79228162514264337593543950336; // 1:1 price
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;

    // Events to test
    event RelayerGranted(address indexed account);
    event RelayerRevoked(address indexed account);

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

        // Deploy factory
        factory = new MultiPositionFactory(factoryOwner, manager);

        // Deploy a MultiPositionManager
        address mpmAddr = factory.deployMultiPositionManager(poolKey, managerOwner, "Test MPM");
        mpm = MultiPositionManager(payable(mpmAddr));

        // Setup strategy
        strategy = new ExponentialStrategy();

        // Setup lens
        lens = new SimpleLens(manager);

        vm.prank(managerOwner);

        // Mint tokens and setup initial liquidity
        token0.mint(managerOwner, 1000e18);
        token1.mint(managerOwner, 1000e18);

        vm.startPrank(managerOwner);
        token0.approve(address(mpm), type(uint256).max);
        token1.approve(address(mpm), type(uint256).max);
        mpm.deposit(100e18, 100e18, managerOwner, managerOwner);
        vm.stopPrank();
    }

    function test_OwnerCanGrantRebalancerRole() public {
        assertFalse(mpm.isRelayer(relayer1));

        // Owner grants role
        vm.expectEmit(true, false, false, false);
        emit RelayerGranted(relayer1);

        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);

        assertTrue(mpm.isRelayer(relayer1));
    }

    function test_OwnerCanRevokeRebalancerRole() public {
        // First grant the role
        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);
        assertTrue(mpm.isRelayer(relayer1));

        // Then revoke it
        vm.expectEmit(true, false, false, false);
        emit RelayerRevoked(relayer1);

        vm.prank(managerOwner);
        mpm.revokeRelayerRole(relayer1);

        assertFalse(mpm.isRelayer(relayer1));
    }

    function test_NonOwnerCannotGrantRole() public {
        vm.expectRevert();
        vm.prank(alice);
        mpm.grantRelayerRole(relayer1);

        vm.expectRevert();
        vm.prank(relayer2);
        mpm.grantRelayerRole(relayer1);
    }

    function test_NonOwnerCannotRevokeRole() public {
        // First grant role as owner
        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);

        // Try to revoke as non-owner
        vm.expectRevert();
        vm.prank(alice);
        mpm.revokeRelayerRole(relayer1);

        vm.expectRevert();
        vm.prank(relayer1); // Even the relayer themselves can't revoke
        mpm.revokeRelayerRole(relayer1);

        // Verify role is still active
        assertTrue(mpm.isRelayer(relayer1));
    }

    function test_RebalancerCanCallRebalance() public {
        // Grant relayer role
        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);

        // Setup rebalance params
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 900,
            tRight: 900,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false
        });

        uint256[2][] memory outMin = new uint256[2][](0);

        (uint256[2][] memory calculatedOutMin, uint256[2][] memory inMin1) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // Rebalancer can call rebalance
        vm.prank(relayer1);
        mpm.rebalance(params, outMin, inMin1);

        // Verify rebalance occurred by checking last strategy params
        (address lastStrategy,,,,,,,,,) = mpm.lastStrategyParams();
        assertEq(lastStrategy, address(strategy));
    }

    function test_OwnerCanStillCallRebalance() public {
        // Setup rebalance params
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 900,
            tRight: 900,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false
        });

        uint256[2][] memory outMin = new uint256[2][](0);

        (uint256[2][] memory calculatedOutMin2, uint256[2][] memory inMin2) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // Owner can call rebalance even without relayer role
        vm.prank(managerOwner);
        mpm.rebalance(params, outMin, inMin2);

        // Verify rebalance occurred
        (address lastStrategy,,,,,,,,,) = mpm.lastStrategyParams();
        assertEq(lastStrategy, address(strategy));
    }

    function test_NonRebalancerCannotCallRebalance() public {
        // Setup rebalance params
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 900,
            tRight: 900,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false
        });

        uint256[2][] memory outMin = new uint256[2][](0);

        (uint256[2][] memory calculatedOutMin3, uint256[2][] memory inMin3) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // Non-rebalancer cannot call rebalance
        vm.expectRevert();
        vm.prank(alice);
        mpm.rebalance(params, outMin, inMin3);
    }

    function test_MultipleRebalancers() public {
        // Grant role to multiple relayers
        vm.startPrank(managerOwner);
        mpm.grantRelayerRole(relayer1);
        mpm.grantRelayerRole(relayer2);
        vm.stopPrank();

        assertTrue(mpm.isRelayer(relayer1));
        assertTrue(mpm.isRelayer(relayer2));

        // Setup rebalance params
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 900,
            tRight: 900,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false
        });

        uint256[2][] memory outMin = new uint256[2][](0);

        (uint256[2][] memory calculatedOutMin4, uint256[2][] memory inMin4) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // First relayer can call rebalance
        vm.prank(relayer1);
        mpm.rebalance(params, outMin, inMin4);

        {
            // After first rebalance, positions exist, so we need proper outMin array
            outMin = new uint256[2][](mpm.basePositionsLength() + mpm.limitPositionsLength());
        }

        {
            (, uint256[2][] memory inMin5) =             SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

            // Second relayer can also call rebalance
            vm.prank(relayer2);
            mpm.rebalance(params, outMin, inMin5);
        }
    }

    function test_RevokedRebalancerCannotCallRebalance() public {
        // Grant then revoke role
        vm.startPrank(managerOwner);
        mpm.grantRelayerRole(relayer1);
        mpm.revokeRelayerRole(relayer1);
        vm.stopPrank();

        assertFalse(mpm.isRelayer(relayer1));

        // Setup rebalance params
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 900,
            tRight: 900,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false
        });

        uint256[2][] memory outMin = new uint256[2][](0);

        (uint256[2][] memory calculatedOutMin6, uint256[2][] memory inMin6) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: mpm,
            strategyAddress: params.strategy,
            centerTick: params.center,
            ticksLeft: params.tLeft,
            ticksRight: params.tRight,
            limitWidth: params.limitWidth,
            weight0: params.weight0,
            weight1: params.weight1,
            useCarpet: params.useCarpet,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // Revoked relayer cannot call rebalance
        vm.expectRevert();
        vm.prank(relayer1);
        mpm.rebalance(params, outMin, inMin6);
    }

    function test_CannotGrantRoleToZeroAddress() public {
        vm.expectRevert();
        vm.prank(managerOwner);
        mpm.grantRelayerRole(address(0));
    }

    function test_CannotGrantRoleToClaimManager() public {
        address claimManager = makeAddr("claimManager");
        vm.startPrank(factoryOwner);
        factory.grantRole(factory.CLAIM_MANAGER(), claimManager);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(managerOwner);
        mpm.grantRelayerRole(claimManager);
    }

    function test_DoubleGrantDoesNotRevert() public {
        // First grant
        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);
        assertTrue(mpm.isRelayer(relayer1));

        // Second grant - should not revert, just no-op
        vm.prank(managerOwner);
        mpm.grantRelayerRole(relayer1);
        assertTrue(mpm.isRelayer(relayer1));
    }

    function test_RevokeNonExistentRoleDoesNotRevert() public {
        assertFalse(mpm.isRelayer(relayer1));

        // Revoke non-existent role - should not revert
        vm.prank(managerOwner);
        mpm.revokeRelayerRole(relayer1);

        assertFalse(mpm.isRelayer(relayer1));
    }
}
