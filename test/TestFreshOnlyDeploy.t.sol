// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract TestFreshOnlyDeploy is Test, Deployers {
    MultiPositionFactory factory;
    ExponentialStrategy strategy;
    PoolKey poolKey;
    MockERC20 token0;
    MockERC20 token1;
    address managerOwner;

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        Currency currency0;
        Currency currency1;
        if (address(token0) < address(token1)) {
            currency0 = Currency.wrap(address(token0));
            currency1 = Currency.wrap(address(token1));
        } else {
            currency0 = Currency.wrap(address(token1));
            currency1 = Currency.wrap(address(token0));
        }

        (poolKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        factory = new MultiPositionFactory(address(this), manager);
        strategy = new ExponentialStrategy();
        managerOwner = address(this);
    }

    function test_DeployDepositAndRebalance_AllowsFreshExistingManager() public {
        string memory name = "Fresh MPM";
        address predicted = factory.computeAddress(poolKey, managerOwner, name);

        token0.approve(predicted, type(uint256).max);
        token1.approve(predicted, type(uint256).max);

        address preDeployed = factory.deployMultiPositionManager(poolKey, managerOwner, name);
        assertEq(preDeployed, predicted, "Expected predicted MPM address");

        IMultiPositionManager.RebalanceParams memory params = _rebalanceParams();
        address mpm = factory.deployDepositAndRebalance(
            poolKey,
            managerOwner,
            name,
            10 ether,
            10 ether,
            address(this),
            new uint256[2][](0),
            params
        );

        assertEq(mpm, predicted, "Expected existing MPM address");
        assertGt(IMultiPositionManager(mpm).totalSupply(), 0, "Expected shares to be minted");
    }

    function test_DeployDepositAndRebalance_RevertsForInitializedManager() public {
        string memory name = "Initialized MPM";
        address predicted = factory.computeAddress(poolKey, managerOwner, name);

        token0.approve(predicted, type(uint256).max);
        token1.approve(predicted, type(uint256).max);

        IMultiPositionManager.RebalanceParams memory params = _rebalanceParams();
        address mpm = factory.deployDepositAndRebalance(
            poolKey,
            managerOwner,
            name,
            10 ether,
            10 ether,
            address(this),
            new uint256[2][](0),
            params
        );

        assertGt(IMultiPositionManager(mpm).totalSupply(), 0, "Expected shares to be minted");

        vm.expectRevert(MultiPositionFactory.MPMAlreadyInitialized.selector);
        factory.deployDepositAndRebalance(
            poolKey,
            managerOwner,
            name,
            1 ether,
            1 ether,
            address(this),
            new uint256[2][](0),
            params
        );
    }

    function test_DeployDepositAndRebalance_RevertsWhenPoolUninitialized() public {
        PoolKey memory uninitializedPoolKey = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 500, // distinct pool key from setUp() initialized pool
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        assertFalse(factory.isPoolInitialized(uninitializedPoolKey), "Pool should start uninitialized");

        vm.expectRevert(MultiPositionFactory.PoolNotInitialized.selector);
        factory.deployDepositAndRebalance(
            uninitializedPoolKey,
            managerOwner,
            "Uninitialized MPM",
            1 ether,
            1 ether,
            address(this),
            new uint256[2][](0),
            _rebalanceParams()
        );
    }

    function test_DeployDepositAndRebalanceSwap_RevertsWhenPoolUninitialized() public {
        PoolKey memory uninitializedPoolKey = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 501, // distinct pool key from setUp() initialized pools
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        assertFalse(factory.isPoolInitialized(uninitializedPoolKey), "Pool should start uninitialized");

        address router = makeAddr("router");
        factory.setAggregatorAddress(uint8(RebalanceLogic.Aggregator.ZERO_X), router);

        RebalanceLogic.SwapParams memory swapParams = RebalanceLogic.SwapParams({
            aggregator: RebalanceLogic.Aggregator.ZERO_X,
            aggregatorAddress: router,
            swapData: bytes(""),
            swapToken0: true,
            swapAmount: 0,
            minAmountOut: 0
        });

        vm.expectRevert(MultiPositionFactory.PoolNotInitialized.selector);
        factory.deployDepositAndRebalanceSwap(
            uninitializedPoolKey,
            managerOwner,
            "Uninitialized MPM Swap",
            1 ether,
            1 ether,
            address(this),
            swapParams,
            new uint256[2][](0),
            _rebalanceParams()
        );
    }

    function _rebalanceParams() private view returns (IMultiPositionManager.RebalanceParams memory) {
        return IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: type(int24).max,
            tLeft: 1000,
            tRight: 1000,
            limitWidth: 0,
            weight0: 5e17,
            weight1: 5e17,
            useCarpet: false
        });
    }
}
