// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {RelayerFactory} from "../src/MultiPositionManager/RelayerFactory.sol";
import {IRelayerFactory} from "../src/MultiPositionManager/interfaces/IRelayerFactory.sol";
import {IRelayer} from "../src/MultiPositionManager/interfaces/IRelayer.sol";
import {Relayer} from "../src/MultiPositionManager/Relayer.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {SingleUniformStrategy} from "../src/MultiPositionManager/strategies/SingleUniformStrategy.sol";

contract RelayerFactoryTest is Test, Deployers {
    RelayerFactory relayerFactory;
    MultiPositionFactory mpmFactory;
    SingleUniformStrategy strategy;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address automationService1 = makeAddr("automationService1");
    address automationService2 = makeAddr("automationService2");

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    address mpm;

    function setUp() public {
        // Deploy pool manager
        deployFreshManagerAndRouters();

        // Fund test addresses with ETH for deployRelayer calls
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(owner, 100 ether);

        // Deploy tokens
        token0 = new MockERC20("Test Token 0", "TEST0", 18);
        token1 = new MockERC20("Test Token 1", "TEST1", 18);

        // Initialize pool
        (poolKey,) = initPool(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), IHooks(address(0)), 3000, SQRT_PRICE_1_1
        );

        // Deploy strategy
        strategy = new SingleUniformStrategy();

        // Deploy MultiPositionFactory
        vm.startPrank(owner);
        mpmFactory = new MultiPositionFactory(owner, manager);
        vm.stopPrank();

        // Deploy a MultiPositionManager for testing
        vm.prank(alice);
        mpm = mpmFactory.deployMultiPositionManager(poolKey, alice, "Test MPM");

        // Deploy RelayerFactory and grant FEE_MANAGER role
        vm.startPrank(owner);
        relayerFactory = new RelayerFactory(owner, mpmFactory);
        mpmFactory.grantRole(mpmFactory.FEE_MANAGER(), address(relayerFactory));
        vm.stopPrank();
    }

    function _getDefaultTriggerConfig() internal view returns (IRelayer.TriggerConfig memory) {
        return IRelayer.TriggerConfig({
            baseLowerTrigger: 100,
            baseUpperTrigger: 100,
            limitDeltaTicks: 50,
            maxDeltaTicks: 1500,
            baseTwapTickTrigger: 0,
            baseMinRatio: 0.3e18,
            baseMaxRatio: 0.7e18,
            limitMinRatio: 0.2e18,
            limitThreshold: 0.2e18,
            outOfPositionThreshold: 0.05e18
        });
    }

    function _getDefaultStrategyParams() internal view returns (IRelayer.StrategyParams memory) {
        return IRelayer.StrategyParams({
            ticksLeft: 6000,
            ticksRight: 6000,
            useCarpet: false,
            limitWidth: 600,
            strategy: address(strategy),
            weight0: 0.5e18,
            weight1: 0.5e18,
            isolatedBaseLimitRebalancing: false,
            useRebalanceSwap: false,
            isBaseRatio: true,
            compoundFees: true,
            maxSwapSlippageBps: 0
        });
    }

    function _getDefaultVolatilityParams() internal pure returns (IRelayer.VolatilityParams memory) {
        return IRelayer.VolatilityParams({geckoIdToken0: "", geckoIdToken1: "", pairType: 0});
    }

    function _getDefaultWithdrawalParams() internal pure returns (IRelayer.WithdrawalParams memory) {
        return IRelayer.WithdrawalParams({
            pool0RatioThreshold: 0,
            pool1RatioThreshold: 0
        });
    }

    function _getDefaultCompoundSwapParams() internal pure returns (IRelayer.CompoundSwapParams memory) {
        return IRelayer.CompoundSwapParams({
            outOfPositionRatioThreshold: 0 // Disabled by default
        });
    }

    function _getDefaultTwapParams() internal pure returns (IRelayer.TwapParams memory) {
        return IRelayer.TwapParams({
            useTwapProtection: false,
            useTwapCenter: false,
            twapSeconds: 1800,
            maxTickDeviation: 0
        });
    }

    function test_Deploy() public view {
        assertEq(relayerFactory.owner(), owner);
        assertEq(relayerFactory.getTotalRelayersCount(), 0);
    }

    function test_RevertDeployWithZeroAddress() public {
        // Test zero owner
        vm.expectRevert();
        new RelayerFactory(address(0), mpmFactory);

        // Test zero multiPositionFactory
        vm.expectRevert(IRelayerFactory.InvalidAddress.selector);
        new RelayerFactory(owner, MultiPositionFactory(address(0)));
    }

    function test_RevertDeployWithInvalidRatios() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        triggerConfig.baseMaxRatio = 1.1e18;

        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        vm.prank(alice);
        vm.expectRevert(IRelayer.InvalidTriggerConfig.selector);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm,
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );
    }

    function test_GrantRole() public {
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        vm.prank(owner);
        relayerFactory.grantRole(role, automationService1);

        assertTrue(relayerFactory.hasRole(role, automationService1));
        assertTrue(relayerFactory.hasRoleOrOwner(role, automationService1));
    }

    function test_RevokeRole() public {
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        // Grant role first
        vm.prank(owner);
        relayerFactory.grantRole(role, automationService1);
        assertTrue(relayerFactory.hasRole(role, automationService1));

        // Revoke role
        vm.prank(owner);
        relayerFactory.revokeRole(role, automationService1);
        assertFalse(relayerFactory.hasRole(role, automationService1));
    }

    function test_RevertGrantRoleNonOwner() public {
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        vm.prank(alice);
        vm.expectRevert();
        relayerFactory.grantRole(role, automationService1);
    }

    function test_RevertRevokeRoleNonOwner() public {
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        vm.prank(owner);
        relayerFactory.grantRole(role, automationService1);

        vm.prank(alice);
        vm.expectRevert();
        relayerFactory.revokeRole(role, automationService1);
    }

    function test_HasRoleOrOwner() public {
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        // Owner should always have role
        assertTrue(relayerFactory.hasRoleOrOwner(role, owner));

        // Non-owner without role should not have access
        assertFalse(relayerFactory.hasRoleOrOwner(role, alice));

        // Grant role and check again
        vm.prank(owner);
        relayerFactory.grantRole(role, alice);
        assertTrue(relayerFactory.hasRoleOrOwner(role, alice));
    }

    function test_DeployRebalancer() public {
        // Create configs
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy relayer as MPM owner
        vm.prank(alice);
        address relayer = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Verify deployment
        assertTrue(relayer != address(0));
        assertEq(relayerFactory.getTotalRelayersCount(), 1);

        // Verify relayer info
        IRelayerFactory.RelayerInfo memory info = relayerFactory.getRelayerInfo(relayer);
        assertEq(info.relayerAddress, relayer);
        assertEq(info.multiPositionManager, mpm);
        assertEq(info.owner, alice);
        assertEq(info.deployedAt, block.timestamp);

        // Verify tracking
        address relayerByMpm = relayerFactory.getRelayerByManager(mpm);
        assertEq(relayerByMpm, relayer);

        address[] memory relayersByOwner = relayerFactory.getRelayersByOwner(alice);
        assertEq(relayersByOwner.length, 1);
        assertEq(relayersByOwner[0], relayer);
    }

    function test_RevertDeployRebalancerNotMPMOwner() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Try to deploy as non-owner (bob)
        vm.prank(bob);
        vm.expectRevert(IRelayerFactory.UnauthorizedAccess.selector);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );
    }

    function test_DeployMultipleRebalancersForDifferentManagers() public {
        // Deploy second MPM for alice
        vm.prank(alice);
        address mpm2 = mpmFactory.deployMultiPositionManager(poolKey, alice, "Test MPM 2");

        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy two relayers for different managers
        vm.startPrank(alice);
        address relayer1 = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );
        address relayer2 = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm2, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );
        vm.stopPrank();

        // Verify total count
        assertEq(relayerFactory.getTotalRelayersCount(), 2);

        // Verify alice owns both
        address[] memory aliceRelayers = relayerFactory.getRelayersByOwner(alice);
        assertEq(aliceRelayers.length, 2);

        // Verify 1:1 mapping per manager
        assertEq(relayerFactory.getRelayerByManager(mpm), relayer1);
        assertEq(relayerFactory.getRelayerByManager(mpm2), relayer2);
    }

    function test_ComputeRelayerAddress_RevertsOnOwnerMismatch() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        vm.expectRevert(IRelayerFactory.UnauthorizedAccess.selector);
        relayerFactory.computeRelayerAddress(
            mpm,
            bob,
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );
    }

    function test_RevertDeploySecondRebalancerForSameManager() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy first relayer
        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Try to deploy second relayer for same manager - should revert
        vm.prank(alice);
        vm.expectRevert(IRelayerFactory.RelayerAlreadyExists.selector);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );
    }

    function test_GetAllRebalancersPaginated() public {
        // Deploy multiple relayers
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        vm.prank(alice);
        address relayer1 = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Deploy MPM for bob
        vm.prank(bob);
        address mpm2 = mpmFactory.deployMultiPositionManager(poolKey, bob, "Bob MPM");

        vm.prank(bob);
        address relayer2 = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm2, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Test pagination
        (IRelayerFactory.RelayerInfo[] memory infos, uint256 total) = relayerFactory.getAllRelayersPaginated(0, 0);

        assertEq(total, 2);
        assertEq(infos.length, 2);
        assertEq(infos[0].relayerAddress, relayer1);
        assertEq(infos[1].relayerAddress, relayer2);

        // Test pagination with limit
        (infos, total) = relayerFactory.getAllRelayersPaginated(0, 1);
        assertEq(total, 2);
        assertEq(infos.length, 1);
        assertEq(infos[0].relayerAddress, relayer1);

        // Test pagination with offset
        (infos, total) = relayerFactory.getAllRelayersPaginated(1, 1);
        assertEq(total, 2);
        assertEq(infos.length, 1);
        assertEq(infos[0].relayerAddress, relayer2);
    }

    function test_GetRebalancerByManager() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy relayer
        vm.prank(alice);
        address relayer = relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Get by manager
        address fetchedRebalancer = relayerFactory.getRelayerByManager(mpm);
        assertEq(fetchedRebalancer, relayer);

        // Query non-existent manager returns address(0)
        address emptyRebalancer = relayerFactory.getRelayerByManager(address(0x123));
        assertEq(emptyRebalancer, address(0));
    }

    function test_GetUniqueTokenPairs() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy first relayer for alice (TEST0/TEST1)
        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Deploy second MPM for bob with same tokens (different manager, same pair)
        vm.prank(bob);
        address mpm2 = mpmFactory.deployMultiPositionManager(poolKey, bob, "Bob MPM");

        vm.prank(bob);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm2, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Get unique token pairs
        (IRelayerFactory.TokenPairInfo[] memory pairs, uint256 total) = relayerFactory.getUniqueTokenPairs(0, 0);

        // Should only have 1 unique pair (TEST0/TEST1) despite 2 managers
        assertEq(total, 1);
        assertEq(pairs.length, 1);
        assertEq(pairs[0].token0Symbol, "TEST0");
        assertEq(pairs[0].token1Symbol, "TEST1");
        assertEq(pairs[0].token0Address, address(token0));
        assertEq(pairs[0].token1Address, address(token1));
        assertEq(pairs[0].token0Decimals, 18);
        assertEq(pairs[0].token1Decimals, 18);
    }

    function test_GetUniqueTokenPairsWithNativeETH() public {
        MockERC20 nativeToken = new MockERC20("Native Pair Token", "NAT", 6);

        (PoolKey memory nativePoolKey,) = initPool(
            Currency.wrap(address(0)),
            Currency.wrap(address(nativeToken)),
            IHooks(address(0)),
            3000,
            SQRT_PRICE_1_1
        );

        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        vm.prank(alice);
        address nativeMpm = mpmFactory.deployMultiPositionManager(nativePoolKey, alice, "Native MPM");

        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            nativeMpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        (IRelayerFactory.TokenPairInfo[] memory pairs, uint256 total) = relayerFactory.getUniqueTokenPairs(0, 0);

        assertEq(total, 1);
        assertEq(pairs.length, 1);
        assertEq(pairs[0].token0Symbol, "ETH");
        assertEq(pairs[0].token1Symbol, "NAT");
        assertEq(pairs[0].token0Address, address(0));
        assertEq(pairs[0].token1Address, address(nativeToken));
        assertEq(pairs[0].token0Decimals, 18);
        assertEq(pairs[0].token1Decimals, 6);
    }

    function test_GetUniqueTokenPairsPagination() public {
        // Deploy 3 different pools with different token pairs
        MockERC20 tokenA = new MockERC20("Token A", "TOKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TOKB", 18);
        MockERC20 tokenC = new MockERC20("Token C", "TOKC", 18);

        // Create pool keys for different pairs (currencies must be sorted)
        (Currency currency0_2, Currency currency1_2) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        (PoolKey memory poolKey2,) = initPool(currency0_2, currency1_2, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        (Currency currency0_3, Currency currency1_3) = address(tokenB) < address(tokenC)
            ? (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenC)))
            : (Currency.wrap(address(tokenC)), Currency.wrap(address(tokenB)));

        (PoolKey memory poolKey3,) = initPool(currency0_3, currency1_3, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy MPMs and relayers for each pool
        vm.prank(alice);
        address mpm1 = mpmFactory.deployMultiPositionManager(poolKey, alice, "MPM1");
        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm1, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        vm.prank(alice);
        address mpm2 = mpmFactory.deployMultiPositionManager(poolKey2, alice, "MPM2");
        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm2, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        vm.prank(alice);
        address mpm3 = mpmFactory.deployMultiPositionManager(poolKey3, alice, "MPM3");
        vm.prank(alice);
        relayerFactory.deployRelayer{value: 0.001 ether}(
            mpm3, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Get all unique pairs
        (IRelayerFactory.TokenPairInfo[] memory allPairs, uint256 totalAll) = relayerFactory.getUniqueTokenPairs(0, 0);

        assertEq(totalAll, 3, "Should have 3 unique pairs");
        assertEq(allPairs.length, 3);

        // Test pagination - get first 2
        (IRelayerFactory.TokenPairInfo[] memory firstTwo, uint256 total1) = relayerFactory.getUniqueTokenPairs(0, 2);

        assertEq(total1, 3, "Total should still be 3");
        assertEq(firstTwo.length, 2, "Should return 2 pairs");

        // Test pagination - get last 1
        (IRelayerFactory.TokenPairInfo[] memory lastOne, uint256 total2) = relayerFactory.getUniqueTokenPairs(2, 1);

        assertEq(total2, 3, "Total should still be 3");
        assertEq(lastOne.length, 1, "Should return 1 pair");
    }

    function testFuzz_GrantAndRevokeRole(address account) public {
        vm.assume(account != address(0));
        bytes32 role = relayerFactory.AUTOMATION_SERVICE_ROLE();

        // Grant role
        vm.prank(owner);
        relayerFactory.grantRole(role, account);
        assertTrue(relayerFactory.hasRole(role, account));

        // Revoke role
        vm.prank(owner);
        relayerFactory.revokeRole(role, account);
        assertFalse(relayerFactory.hasRole(role, account));
    }

    function test_ComputeRebalancerAddress() public {
        IRelayer.TriggerConfig memory triggerConfig = _getDefaultTriggerConfig();
        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Pre-compute the address
        address predictedAddress = relayerFactory.computeRelayerAddress(
            mpm, alice, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Give alice some ETH for funding the relayer
        vm.deal(alice, 1 ether);

        // Deploy the relayer
        vm.prank(alice);
        address deployedAddress = relayerFactory.deployRelayer{value: 0.1 ether}(
            mpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Verify the addresses match
        assertEq(predictedAddress, deployedAddress, "Predicted address should match deployed address");
    }

    function test_DeployRebalancerWithMaxDeltaTicksZero() public {
        // Test that maxDeltaTicks = 0 means "no circuit breaker"
        // This should now succeed with baseLowerTrigger > 0
        IRelayer.TriggerConfig memory triggerConfig = IRelayer.TriggerConfig({
            baseLowerTrigger: 2500,
            baseUpperTrigger: 2500,
            limitDeltaTicks: 0,
            maxDeltaTicks: 0, // 0 means no circuit breaker
            baseTwapTickTrigger: 0,
            baseMinRatio: 0,
            baseMaxRatio: 0,
            limitMinRatio: 0,
            limitThreshold: 0,
            outOfPositionThreshold: 0
        });

        IRelayer.StrategyParams memory strategyParams = _getDefaultStrategyParams();
        IRelayer.VolatilityParams memory volatilityParams = _getDefaultVolatilityParams();
        IRelayer.WithdrawalParams memory withdrawalParams = _getDefaultWithdrawalParams();
        IRelayer.CompoundSwapParams memory compoundSwapParams = _getDefaultCompoundSwapParams();
        IRelayer.TwapParams memory twapParams = _getDefaultTwapParams();

        // Deploy a new MPM for this test (since we already deployed one for alice)
        vm.prank(bob);
        address newMpm = mpmFactory.deployMultiPositionManager(poolKey, bob, "Test MPM 2");

        // Deploy relayer with maxDeltaTicks = 0
        vm.prank(bob);
        address relayer = relayerFactory.deployRelayer{value: 0.001 ether}(
            newMpm, triggerConfig, strategyParams, volatilityParams, withdrawalParams, compoundSwapParams, twapParams
        );

        // Verify deployment succeeded
        assertTrue(relayer != address(0), "Rebalancer should deploy successfully");

        // Verify trigger config was stored correctly (maxDeltaTicks stays 0)
        (IRelayer.TriggerConfig memory storedConfig,,,) = Relayer(payable(relayer)).getRebalanceParams();
        assertEq(storedConfig.maxDeltaTicks, 0, "maxDeltaTicks should be 0 (no circuit breaker)");
        assertEq(storedConfig.baseLowerTrigger, 2520, "baseLowerTrigger should be rounded up to tickSpacing");
    }
}
