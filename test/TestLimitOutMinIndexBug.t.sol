// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "../src/MultiPositionManager/interfaces/IMultiPositionFactory.sol";
import {ExponentialStrategy} from "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {SimpleLensInMin} from "../src/MultiPositionManager/libraries/SimpleLens/SimpleLensInMin.sol";
import {PoolManagerUtils} from "../src/MultiPositionManager/libraries/PoolManagerUtils.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

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

contract TestableMultiPositionManager is MultiPositionManager {
    constructor(
        IPoolManager poolManager,
        PoolKey memory poolKey,
        address owner,
        address factory,
        string memory name,
        string memory symbol,
        uint16 fee
    ) MultiPositionManager(poolManager, poolKey, owner, factory, name, symbol, fee) {}

    function setBasePositions(IMultiPositionManager.Range[] memory ranges) external {
        s.basePositionsLength = ranges.length;
        for (uint256 i = 0; i < ranges.length; i++) {
            s.basePositions[i] = ranges[i];
        }
    }

    function setLimitPositions(IMultiPositionManager.Range memory limit0, IMultiPositionManager.Range memory limit1, uint256 length) external {
        s.limitPositions[0] = limit0;
        s.limitPositions[1] = limit1;
        s.limitPositionsLength = length;
    }
}

contract TestCompoundLimitIndexBug is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    MockERC20 token0;
    MockERC20 token1;
    MockFactory mockFactory;
    TestableMultiPositionManager multiPositionManager;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");

    uint24 internal constant FEE_TIER = 500;
    bytes32 private constant POSITION_ID = bytes32(uint256(1));
    bytes4 private constant EXTSLOAD_SELECTOR = bytes4(keccak256("extsload(bytes32,uint256)"));

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Test Token 0", "TEST0", 18);
        token1 = new MockERC20("Test Token 1", "TEST1", 18);

        uint160 sqrtInit = TickMath.getSqrtPriceAtTick(0);
        IHooks hooks;
        (key,) = initPool(Currency.wrap(address(token0)), Currency.wrap(address(token1)), hooks, FEE_TIER, sqrtInit);

        mockFactory = new MockFactory(feeRecipient);
        multiPositionManager = new TestableMultiPositionManager(
            manager,
            key,
            owner,
            address(mockFactory),
            "TOKEN0-TOKEN1",
            "TOKEN0-TOKEN1",
            10
        );
    }

    function _positionInfoSlot(address mpmAddr, IMultiPositionManager.Range memory range) internal view returns (bytes32) {
        bytes32 positionKey = Position.calculatePositionKey(mpmAddr, range.lowerTick, range.upperTick, POSITION_ID);
        PoolId poolId = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        bytes32 positionMapping = bytes32(uint256(stateSlot) + StateLibrary.POSITIONS_OFFSET);
        return keccak256(abi.encodePacked(positionKey, positionMapping));
    }

    function _mockPositionLiquidity(address mpmAddr, IMultiPositionManager.Range memory range, uint128 liquidity) internal {
        bytes32 slot = _positionInfoSlot(mpmAddr, range);
        bytes32[] memory values = new bytes32[](3);
        values[0] = bytes32(uint256(liquidity));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(EXTSLOAD_SELECTOR, slot, uint256(3)),
            abi.encode(values)
        );
    }

    function test_Compound_AddsLiquidity_ToLimit1_When_Limit0Empty() public {
        vm.startPrank(owner);

        IMultiPositionManager.Range[] memory baseRanges = new IMultiPositionManager.Range[](1);
        baseRanges[0] = IMultiPositionManager.Range({lowerTick: -100, upperTick: 100});
        multiPositionManager.setBasePositions(baseRanges);

        IMultiPositionManager.Range memory limit0 = IMultiPositionManager.Range({lowerTick: 0, upperTick: 0});
        IMultiPositionManager.Range memory limit1 = IMultiPositionManager.Range({lowerTick: 200, upperTick: 300});
        multiPositionManager.setLimitPositions(limit0, limit1, 1);

        uint128 seedLiquidity = 1e18;
        _mockPositionLiquidity(address(multiPositionManager), limit1, seedLiquidity);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(limit1.lowerTick);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(limit1.upperTick);
        (uint256 idle0, uint256 idle1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, seedLiquidity);
        require(idle0 != 0 || idle1 != 0, "expected non-zero amounts");

        if (idle0 != 0) {
            token0.mint(owner, idle0);
            token0.transfer(address(multiPositionManager), idle0);
        }
        if (idle1 != 0) {
            token1.mint(owner, idle1);
            token1.transfer(address(multiPositionManager), idle1);
        }

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLower,
            sqrtPriceUpper,
            idle0,
            idle1
        );
        require(expectedLiquidity != 0, "expected non-zero liquidity");

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: limit1.lowerTick,
            tickUpper: limit1.upperTick,
            liquidityDelta: int256(int128(expectedLiquidity)),
            salt: POSITION_ID
        });
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector, key, params, bytes(""))
        );
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector, key, params, bytes("")),
            abi.encode(BalanceDelta.wrap(0), BalanceDelta.wrap(0))
        );

        multiPositionManager.compound(new uint256[2][](0));
        vm.stopPrank();
    }
}

contract TestLimitOutMinIndexBug is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    MultiPositionManager multiPositionManager;
    MockERC20 token0;
    MockERC20 token1;
    ExponentialStrategy exponentialStrategy;
    MockFactory mockFactory;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");

    uint24 internal constant FEE_TIER = 2000;
    uint24 internal constant LIMIT_WIDTH = 600;
    uint24 internal constant TICKS_LEFT = 800;
    uint24 internal constant TICKS_RIGHT = 800;
    bytes32 private constant POSITION_ID = bytes32(uint256(1));
    bytes4 private constant EXTSLOAD_SELECTOR = bytes4(keccak256("extsload(bytes32,uint256)"));

    function setUp() public {
        deployFreshManagerAndRouters();

        token0 = new MockERC20("Test Token 0", "TEST0", 18);
        token1 = new MockERC20("Test Token 1", "TEST1", 18);

        int24 tickSpacing = int24(uint24(FEE_TIER / 100 * 2));
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 initTick = minTick + 1;
        uint160 sqrtInit = TickMath.getSqrtPriceAtTick(initTick);

        IHooks hooks;
        (key,) = initPool(Currency.wrap(address(token0)), Currency.wrap(address(token1)), hooks, FEE_TIER, sqrtInit);

        mockFactory = new MockFactory(feeRecipient);
        multiPositionManager = new MultiPositionManager(
            manager,
            key,
            owner,
            address(mockFactory),
            "TOKEN0-TOKEN1-MIN",
            "TOKEN0-TOKEN1-MIN",
            10
        );
        exponentialStrategy = new ExponentialStrategy();
    }

    function _positionInfoSlot(IMultiPositionManager.Range memory range) internal view returns (bytes32) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(multiPositionManager), range.lowerTick, range.upperTick, POSITION_ID);
        PoolId poolId = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
        bytes32 positionMapping = bytes32(uint256(stateSlot) + StateLibrary.POSITIONS_OFFSET);
        return keccak256(abi.encodePacked(positionKey, positionMapping));
    }

    function _mockPositionLiquidity(IMultiPositionManager.Range memory range, uint128 liquidity) internal {
        bytes32 slot = _positionInfoSlot(range);
        bytes32[] memory values = new bytes32[](3);
        values[0] = bytes32(uint256(liquidity));
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(EXTSLOAD_SELECTOR, slot, uint256(3)),
            abi.encode(values)
        );
    }

    function _mockBurnLimitPosition(
        IMultiPositionManager.Range memory range,
        uint128 liquidity,
        BalanceDelta delta
    ) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: range.lowerTick,
            tickUpper: range.upperTick,
            liquidityDelta: -int256(int128(liquidity)),
            salt: POSITION_ID
        });
        vm.mockCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector, key, params, bytes("")),
            abi.encode(delta, BalanceDelta.wrap(0))
        );
    }

    function _seedLimit1Only() internal {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 1 ether;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        (uint256[2][] memory outMin0, uint256[2][] memory inMin0) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            multiPositionManager.CENTER_AT_CURRENT_TICK(),
            TICKS_LEFT,
            TICKS_RIGHT,
            LIMIT_WIDTH,
            0.5e18,
            0.5e18,
            false,
            false,
            500,
            500
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: multiPositionManager.CENTER_AT_CURRENT_TICK(),
                tLeft: TICKS_LEFT,
                tRight: TICKS_RIGHT,
                limitWidth: LIMIT_WIDTH,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin0,
            inMin0
        );

        IMultiPositionManager.Range memory limit0 = multiPositionManager.limitPositions(0);
        IMultiPositionManager.Range memory limit1 = multiPositionManager.limitPositions(1);

        assertEq(limit0.lowerTick, limit0.upperTick, "expected limit[0] empty");
        assertTrue(limit1.lowerTick != limit1.upperTick, "expected limit[1] non-empty");
        assertEq(multiPositionManager.limitPositionsLength(), 1, "expected single active limit");

    }

    function test_Rebalance_OutMinIndexMismatch_When_Limit0_Empty() public {
        vm.startPrank(owner);
        _seedLimit1Only();

        uint256 baseLen = multiPositionManager.basePositionsLength();
        uint256 limitLen = multiPositionManager.limitPositionsLength();
        uint256 outMinLength = baseLen + limitLen;

        uint256 slotIndex = baseLen + 1;
        uint256 packedIndex = baseLen;

        assertEq(limitLen, 1, "expected single active limit position");
        assertGe(slotIndex, outMinLength, "slot index should be out of bounds");
        assertLt(packedIndex, outMinLength, "packed index should be in bounds");
        vm.stopPrank();
    }

    function test_Compound_PackedIndex_When_Limit0_Empty() public {
        vm.startPrank(owner);
        _seedLimit1Only();

        uint256 baseLen = multiPositionManager.basePositionsLength();
        uint256 limitLen = multiPositionManager.limitPositionsLength();
        uint256 inMinLength = baseLen + limitLen;

        uint256 slotIndex = baseLen + 1;
        uint256 packedIndex = baseLen;

        assertEq(limitLen, 1, "expected single active limit position");
        assertGe(slotIndex, inMinLength, "slot index should be out of bounds");
        assertLt(packedIndex, inMinLength, "packed index should be in bounds");
        vm.stopPrank();
    }

    function test_Withdraw_UsesPackedIndex_ForLimit1Slippage() public {
        vm.startPrank(owner);
        _seedLimit1Only();

        uint256 baseLen = multiPositionManager.basePositionsLength();
        IMultiPositionManager.Range memory limit1 = multiPositionManager.limitPositions(1);

        _mockPositionLiquidity(limit1, 1e18);
        (uint128 mockedLiquidity,,) = StateLibrary.getPositionInfo(
            manager, key.toId(), address(multiPositionManager), limit1.lowerTick, limit1.upperTick, POSITION_ID
        );
        assertEq(mockedLiquidity, 1e18, "expected mocked limit[1] liquidity");
        bytes32 slot = _positionInfoSlot(limit1);
        vm.expectCall(address(manager), abi.encodeWithSelector(EXTSLOAD_SELECTOR, slot, uint256(3)));
        BalanceDelta delta = toBalanceDelta(int128(1), int128(0));
        assertEq(delta.amount0(), int128(1), "unexpected mocked delta");
        _mockBurnLimitPosition(limit1, 1e18, delta);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: limit1.lowerTick,
            tickUpper: limit1.upperTick,
            liquidityDelta: -int256(int128(1e18)),
            salt: POSITION_ID
        });
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector, key, params, bytes(""))
        );

        uint256[2][] memory outMin = new uint256[2][](baseLen + 1);
        outMin[baseLen] = [type(uint256).max / 2, type(uint256).max / 2];
        assertEq(outMin[baseLen][0], type(uint256).max / 2, "unexpected outMin[limit]");

        uint256 shares = multiPositionManager.totalSupply();
        vm.expectRevert(PoolManagerUtils.SlippageExceeded.selector);
        multiPositionManager.withdraw(shares, outMin, true);
        vm.stopPrank();
    }

    
}
