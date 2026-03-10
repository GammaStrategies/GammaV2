// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "../src/MultiPositionManager/interfaces/IMultiPositionFactory.sol";
import {ILiquidityStrategy} from "../src/MultiPositionManager/strategies/ILiquidityStrategy.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract MockFactory is IMultiPositionFactory {
    address public feeRecipient;
    uint16 public protocolFee = 10;
    mapping(uint8 => address) public override aggregatorAddress;

    constructor(address _feeRecipient) {
        feeRecipient = _feeRecipient;
    }

    function hasRoleOrOwner(bytes32, address) external pure returns (bool) {
        return true;
    }

    function CLAIM_MANAGER() external pure returns (bytes32) {
        return keccak256("CLAIM_MANAGER");
    }

    function FEE_MANAGER() external pure returns (bytes32) {
        return keccak256("FEE_MANAGER");
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
    }

    function grantRole(bytes32, address) external {}

    function revokeRole(bytes32, address) external {}

    function setFeeRecipient(address _feeRecipient) external {
        feeRecipient = _feeRecipient;
    }

    function setProtocolFee(uint16 _fee) external {
        protocolFee = _fee;
    }

    function deployMultiPositionManager(PoolKey memory, address, string memory) external pure returns (address) {
        return address(0);
    }

    function getManagersByOwner(address) external pure returns (IMultiPositionFactory.ManagerInfo[] memory) {
        return new IMultiPositionFactory.ManagerInfo[](0);
    }

    function managers(address) external pure returns (address, address, PoolKey memory, string memory) {
        return (
            address(0),
            address(0),
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            ""
        );
    }

    function getAllManagersPaginated(uint256, uint256)
        external
        pure
        returns (IMultiPositionFactory.ManagerInfo[] memory, uint256)
    {
        return (new IMultiPositionFactory.ManagerInfo[](0), 0);
    }

    function getTotalManagersCount() external pure returns (uint256) {
        return 0;
    }

    function computeAddress(PoolKey memory, address, string memory) external pure returns (address) {
        return address(0);
    }

    function getAllTokenPairsPaginated(uint256, uint256)
        external
        pure
        returns (IMultiPositionFactory.TokenPairInfo[] memory, uint256)
    {
        return (new IMultiPositionFactory.TokenPairInfo[](0), 0);
    }

    function getAllManagersByTokenPair(address, address, uint256, uint256)
        external
        pure
        returns (IMultiPositionFactory.ManagerInfo[] memory, uint256)
    {
        return (new IMultiPositionFactory.ManagerInfo[](0), 0);
    }
}

contract UnsupportedWeightsStrategy is ILiquidityStrategy {
    function generateRanges(int24 centerTick, uint24, uint24, int24 tickSpacing, bool)
        external
        pure
        override
        returns (int24[] memory lowerTicks, int24[] memory upperTicks)
    {
        lowerTicks = new int24[](1);
        upperTicks = new int24[](1);
        lowerTicks[0] = centerTick - tickSpacing;
        upperTicks[0] = centerTick + tickSpacing;
    }

    function calculateDensities(
        int24[] memory lowerTicks,
        int24[] memory,
        int24,
        int24,
        uint24,
        uint24,
        uint256,
        uint256,
        bool,
        int24,
        bool
    ) external pure override returns (uint256[] memory weights) {
        weights = new uint256[](lowerTicks.length);
        weights[0] = 1e18;
    }

    function supportsWeights() external pure override returns (bool supported) {
        return false;
    }

    function getStrategyType() external pure override returns (string memory) {
        return "UnsupportedWeights";
    }

    function getDescription() external pure override returns (string memory) {
        return "Strategy that does not support explicit weights.";
    }
}

contract TestStrategyWeightSupport is Test, Deployers {
    using CurrencyLibrary for Currency;

    MultiPositionManager mpm;
    MockFactory factory;
    UnsupportedWeightsStrategy strategy;

    function setUp() public {
        deployFreshManagerAndRouters();

        MockERC20 token0 = new MockERC20("Test Token 0", "TEST0", 18);
        MockERC20 token1 = new MockERC20("Test Token 1", "TEST1", 18);

        IHooks hooks;
        (PoolKey memory key,) = initPool(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            hooks,
            3000,
            SQRT_PRICE_1_1
        );

        factory = new MockFactory(address(0));
        mpm = new MultiPositionManager(
            manager,
            key,
            address(this),
            address(factory),
            "TEST",
            "TEST",
            10
        );

        strategy = new UnsupportedWeightsStrategy();
    }

    function test_RevertWhenExplicitWeightsUnsupported() public {
        IMultiPositionManager.RebalanceParams memory params = IMultiPositionManager.RebalanceParams({
            strategy: address(strategy),
            center: 0,
            tLeft: 600,
            tRight: 600,
            limitWidth: 0,
            weight0: 0.7e18,
            weight1: 0.3e18,
            useCarpet: false
        });

        vm.expectRevert(RebalanceLogic.StrategyDoesNotSupportWeights.selector);
        mpm.rebalance(params, new uint256[2][](0), new uint256[2][](0));
    }
}
