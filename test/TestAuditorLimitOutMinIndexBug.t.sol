// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
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

contract TestAuditorLimitOutMinIndexBug is Test, Deployers {
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

        token0.mint(address(this), 2_000_000 ether);
        token1.mint(address(this), 2_000_000 ether);
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

    function test_SlippageIndexingBugDemonstration() public {
        // Setup: 3 base positions, limitPositions[0] empty, limitPositions[1] non-empty
        uint256 basePositionsLength = 3;
        uint256 limitPositionsLength = 1;

        // User provides outMin for all positions they expect
        uint256 outMinLength = basePositionsLength + limitPositionsLength;

        console.log("basePositionsLength:", basePositionsLength);
        console.log("limitPositionsLength:", limitPositionsLength);
        console.log("outMin.length:", outMinLength);

        // During _burnLimitPositions:
        // for i = 0: limitRanges[0] is empty, skipped
        // for i = 1: limitRanges[1] is non-empty
        //   outMinIndex = baseRangesLength + i = 3 + 1 = 4
        //   Check: 4 < 4? FALSE
        //   Falls back to [0, 0]
        uint256 i = 1;
        uint256 outMinIndex = basePositionsLength + i;

        console.log("Processing limit position at slot:", i);
        console.log("outMinIndex:", outMinIndex);
        console.log("outMinIndex < outMinLength:", outMinIndex < outMinLength);

        if (outMinIndex < outMinLength) {
            console.log("Would use user-provided slippage protection");
        } else {
            console.log("Falls back to [0, 0] - No Slippage Protection");
        }

        // The fix should use a counter.
        uint8 limitCount = 0;
        for (uint8 j = 0; j < 2; j++) {
            bool isNonEmpty = (j == 1);
            if (isNonEmpty) {
                uint256 fixedOutMinIndex = basePositionsLength + limitCount;
                console.log("\nWith fix - limitCount:", limitCount);
                console.log("With fix - outMinIndex:", fixedOutMinIndex);
                console.log("With fix - outMinIndex < outMinLength:", fixedOutMinIndex < outMinLength);
                limitCount++;
            }
        }

        assertTrue(outMinIndex >= outMinLength, "Bug confirmed: outMinIndex out of bounds");
    }

    function test_Limit1_OutMin_Ignored_When_Limit0_IsEmpty() public {
        // Deposit
        vm.startPrank(owner);
        token0.mint(owner, 100 ether);
        token1.mint(owner, 100 ether);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);
        multiPositionManager.deposit(100 ether, 100 ether, owner, owner);

        // First rebalance: create base + limit ranges, with limit[0] forced to (0,0)
        (uint256[2][] memory outMin0, uint256[2][] memory inMin0) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
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
                center: 0,
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

        // Confirm we have exactly ONE non-empty limit position exposed via getPositions()
        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        (IMultiPositionManager.Range[] memory baseRanges,) = multiPositionManager.getBasePositions();

        uint256 baseLen = baseRanges.length;
        require(ranges.length == baseLen + 1, "PoC requires exactly 1 active limit position");

        // Verify it's specifically limit[0] empty, limit[1] non-empty
        IMultiPositionManager.Range memory limit0 = multiPositionManager.limitPositions(0);
        IMultiPositionManager.Range memory limit1 = multiPositionManager.limitPositions(1);

        require(limit0.lowerTick == limit0.upperTick, "PoC requires limit[0] to be empty");
        require(limit1.lowerTick != limit1.upperTick, "PoC requires limit[1] to be non-empty");

        // Second rebalance: craft malicious outMin where the LAST element (the only active limit)
        // has impossible mins. If applied correctly, burn should revert.
        (uint256[2][] memory outMinGood, uint256[2][] memory inMin1) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            address(exponentialStrategy),
            0,
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

        require(outMinGood.length == baseLen + 1, "unexpected outMin length");

        uint256[2][] memory outMin = new uint256[2][](outMinGood.length);

        // Make all base mins zero so they don't affect result
        for (uint256 i = 0; i < baseLen; i++) {
            outMin[i] = [uint256(0), uint256(0)];
        }

        // Put an impossible min for the single active limit position (the last element).
        outMin[baseLen] = [type(uint256).max / 2, type(uint256).max / 2];

        _mockPositionLiquidity(limit1, 1e18);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(0));
        _mockBurnLimitPosition(limit1, 1e18, delta);

        vm.expectRevert(PoolManagerUtils.SlippageExceeded.selector);
        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: TICKS_LEFT,
                tRight: TICKS_RIGHT,
                limitWidth: LIMIT_WIDTH,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMin,
            inMin1
        );

        vm.stopPrank();
    }
}
