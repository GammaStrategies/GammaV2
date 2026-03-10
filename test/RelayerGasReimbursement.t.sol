// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IRelayer} from "../src/MultiPositionManager/interfaces/IRelayer.sol";
import {Relayer} from "../src/MultiPositionManager/Relayer.sol";
import {RelayerLogic} from "../src/MultiPositionManager/libraries/RelayerLogic.sol";

contract MockGasPriceOracle {
    uint256 private constant FEE_PER_BYTE = 1_000_000;

    function getL1Fee(bytes calldata data) external pure returns (uint256) {
        return data.length * FEE_PER_BYTE;
    }
}

contract MockTwapManager {
    PoolKey private poolKey_;
    int24 private currentTick_;

    constructor(PoolKey memory _poolKey, int24 _currentTick) {
        poolKey_ = _poolKey;
        currentTick_ = _currentTick;
    }

    function poolKey() external view returns (PoolKey memory) {
        return poolKey_;
    }

    function currentTick() external view returns (int24) {
        return currentTick_;
    }
}

contract RelayerGasHarness is Relayer {
    constructor(
        address _manager,
        address _factory,
        address _owner,
        TriggerConfig memory _triggerConfig,
        StrategyParams memory _strategyParams,
        VolatilityParams memory _volatilityParams,
        WithdrawalParams memory _withdrawalParams,
        CompoundSwapParams memory _compoundSwapParams,
        TwapParams memory _twapParams
    )
        Relayer(
            _manager,
            _factory,
            _owner,
            _triggerConfig,
            _strategyParams,
            _volatilityParams,
            _withdrawalParams,
            _compoundSwapParams,
            _twapParams
        )
    {}

    function exposeCalculate(bytes calldata data)
        external
        view
        returns (uint256 gasUsed, uint256 l1Fee, uint256 reimbursement)
    {
        uint256 gasBefore = gasleft();
        return _calculateReimbursement(gasBefore, data);
    }

    function exposeCalculateBeforeTwap(IRelayer.TwapParams calldata twapParams, bytes calldata data)
        external
        returns (uint256 gasUsed, uint256 l1Fee, uint256 reimbursement)
    {
        uint256 gasBefore = gasleft();
        RelayerLogic.checkTwapProtection(manager, twapParams);
        return _calculateReimbursement(gasBefore, data);
    }

    function exposeCalculateAfterTwap(IRelayer.TwapParams calldata twapParams, bytes calldata data)
        external
        returns (uint256 gasUsed, uint256 l1Fee, uint256 reimbursement)
    {
        RelayerLogic.checkTwapProtection(manager, twapParams);
        uint256 gasBefore = gasleft();
        return _calculateReimbursement(gasBefore, data);
    }
}

contract TestRelayerGasReimbursement is Test, Deployers {
    uint256 private constant FEE_PER_BYTE = 1_000_000;
    uint256 private constant GAS_BUFFER_NUMERATOR = 110;
    uint256 private constant GAS_BUFFER_DENOMINATOR = 100;
    uint256 private constant L1_FEE_PADDING_BYTES = 128;
    address private constant GAS_PRICE_ORACLE = address(0x420000000000000000000000000000000000000F);

    RelayerGasHarness private relayer;

    function setUp() public {
        deployFreshManagerAndRouters();

        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        (PoolKey memory poolKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        MultiPositionFactory mpmFactory = new MultiPositionFactory(address(this), manager);
        MultiPositionManager mpm =
            MultiPositionManager(payable(mpmFactory.deployMultiPositionManager(poolKey, address(this), "MPM")));

        IRelayer.TriggerConfig memory triggerConfig = IRelayer.TriggerConfig({
            baseLowerTrigger: 0,
            baseUpperTrigger: 0,
            limitDeltaTicks: 0,
            maxDeltaTicks: 0,
            baseTwapTickTrigger: 0,
            baseMinRatio: 0,
            baseMaxRatio: 0,
            limitMinRatio: 0,
            limitThreshold: 0,
            outOfPositionThreshold: 0
        });
        IRelayer.StrategyParams memory strategyParams = IRelayer.StrategyParams({
            ticksLeft: 0,
            ticksRight: 0,
            useCarpet: false,
            limitWidth: 0,
            strategy: address(0),
            weight0: 0,
            weight1: 0,
            isolatedBaseLimitRebalancing: false,
            useRebalanceSwap: false,
            isBaseRatio: false,
            compoundFees: true,
            maxSwapSlippageBps: 0
        });
        IRelayer.VolatilityParams memory volatilityParams =
            IRelayer.VolatilityParams({geckoIdToken0: "", geckoIdToken1: "", pairType: 0});
        IRelayer.WithdrawalParams memory withdrawalParams = IRelayer.WithdrawalParams({
            pool0RatioThreshold: 0,
            pool1RatioThreshold: 0
        });
        IRelayer.CompoundSwapParams memory compoundSwapParams =
            IRelayer.CompoundSwapParams({outOfPositionRatioThreshold: 0});
        IRelayer.TwapParams memory twapParams =
            IRelayer.TwapParams({useTwapProtection: false, useTwapCenter: false, twapSeconds: 0, maxTickDeviation: 0});

        relayer = new RelayerGasHarness(
            address(mpm),
            address(this),
            address(this),
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );
    }

    function test_ReimburseGas_IncludesL1Fee() public {
        vm.etch(GAS_PRICE_ORACLE, type(MockGasPriceOracle).runtimeCode);

        vm.txGasPrice(2 gwei);
        bytes memory data = new bytes(256);

        (uint256 gasUsed, uint256 l1Fee, uint256 reimbursement) = relayer.exposeCalculate(data);

        uint256 expectedL1Fee = (data.length + L1_FEE_PADDING_BYTES) * FEE_PER_BYTE;
        uint256 expected = ((gasUsed * tx.gasprice) + expectedL1Fee) * GAS_BUFFER_NUMERATOR / GAS_BUFFER_DENOMINATOR;
        uint256 l2Only = (gasUsed * tx.gasprice * GAS_BUFFER_NUMERATOR) / GAS_BUFFER_DENOMINATOR;

        console.log("gasUsed:", gasUsed);
        console.log("l1Fee:", l1Fee);
        console.log("reimbursement:", reimbursement);
        console.log("expected:", expected);
        console.log("reimbursement (L2-only):", l2Only);
        console.log("delta (L1 fee w/ buffer):", reimbursement - l2Only);

        assertEq(l1Fee, expectedL1Fee);
        assertEq(reimbursement, expected);
    }
}

contract TestRelayerTwapGasReimbursement is Test {
    address private constant HOOK = address(0x1111111111111111111111111111111111111111);
    address private constant ORACLE = address(0x2222222222222222222222222222222222222222);

    PoolKey private poolKey;
    RelayerGasHarness private relayer;

    function setUp() public {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        MockTwapManager manager = new MockTwapManager(poolKey, 0);

        IRelayer.TriggerConfig memory triggerConfig = IRelayer.TriggerConfig({
            baseLowerTrigger: 0,
            baseUpperTrigger: 0,
            limitDeltaTicks: 0,
            maxDeltaTicks: 0,
            baseTwapTickTrigger: 0,
            baseMinRatio: 0,
            baseMaxRatio: 0,
            limitMinRatio: 0,
            limitThreshold: 0,
            outOfPositionThreshold: 0
        });
        IRelayer.StrategyParams memory strategyParams = IRelayer.StrategyParams({
            ticksLeft: 0,
            ticksRight: 0,
            useCarpet: false,
            limitWidth: 0,
            strategy: address(0),
            weight0: 0,
            weight1: 0,
            isolatedBaseLimitRebalancing: false,
            useRebalanceSwap: false,
            isBaseRatio: false,
            compoundFees: true,
            maxSwapSlippageBps: 0
        });
        IRelayer.VolatilityParams memory volatilityParams =
            IRelayer.VolatilityParams({geckoIdToken0: "", geckoIdToken1: "", pairType: 0});
        IRelayer.WithdrawalParams memory withdrawalParams = IRelayer.WithdrawalParams({
            pool0RatioThreshold: 0,
            pool1RatioThreshold: 0
        });
        IRelayer.CompoundSwapParams memory compoundSwapParams =
            IRelayer.CompoundSwapParams({outOfPositionRatioThreshold: 0});
        IRelayer.TwapParams memory twapParams =
            IRelayer.TwapParams({useTwapProtection: false, useTwapCenter: false, twapSeconds: 0, maxTickDeviation: 0});

        relayer = new RelayerGasHarness(
            address(manager),
            address(this),
            address(this),
            triggerConfig,
            strategyParams,
            volatilityParams,
            withdrawalParams,
            compoundSwapParams,
            twapParams
        );
    }

    function test_ReimburseGas_IncludesTwapCheck() public {
        vm.mockCall(HOOK, abi.encodeWithSignature("volatilityOracle()"), abi.encode(ORACLE));

        uint32 twapSeconds = 30;
        vm.mockCall(
            ORACLE,
            abi.encodeWithSignature("consult((address,address,uint24,int24,address),uint32)", poolKey, twapSeconds),
            abi.encode(int24(0), uint128(1))
        );

        IRelayer.TwapParams memory enabledTwapParams = IRelayer.TwapParams({
            useTwapProtection: true,
            useTwapCenter: false,
            twapSeconds: twapSeconds,
            maxTickDeviation: 100
        });

        vm.txGasPrice(1 gwei);
        bytes memory data = new bytes(128);

        (uint256 gasUsedBefore, , uint256 reimbursementBefore) =
            relayer.exposeCalculateBeforeTwap(enabledTwapParams, data);
        (uint256 gasUsedAfter, , uint256 reimbursementAfter) =
            relayer.exposeCalculateAfterTwap(enabledTwapParams, data);

        console.log("gasUsed (before TWAP):", gasUsedBefore);
        console.log("gasUsed (after TWAP):", gasUsedAfter);
        console.log("reimbursement (before TWAP):", reimbursementBefore);
        console.log("reimbursement (after TWAP):", reimbursementAfter);
        console.log("delta:", reimbursementBefore - reimbursementAfter);

        assertGt(gasUsedBefore, gasUsedAfter);
        assertGt(reimbursementBefore, reimbursementAfter);
    }
}
