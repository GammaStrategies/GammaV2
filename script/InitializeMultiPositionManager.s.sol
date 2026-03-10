// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract InitializeMultiPositionManager is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Helper function to handle position setup and rebalance
    function setupPosition(
        MultiPositionManager mpm,
        PoolKey memory poolKey,
        uint256 _deposit0,
        uint256 _deposit1,
        address _poolManager
    ) internal {
        // Get current price data
        (uint160 sqrtPriceX96, int24 currentTick,,) = IPoolManager(_poolManager).getSlot0(poolKey.toId());
        console.log("Current tick:", currentTick);

        // Calculate liquidity and prepare positions
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(-887220),
            TickMath.getSqrtPriceAtTick(887220),
            _deposit0,
            _deposit1
        );

        IMultiPositionManager.Range[] memory positions = new IMultiPositionManager.Range[](1);
        positions[0].lowerTick = -887220;
        positions[0].upperTick = 887220;

        uint128[] memory liq = new uint128[](1);
        liq[0] = liquidity;

        // Get current base positions length
        uint256 basePositionsLength = mpm.basePositionsLength();

        // Set a large limitWidth to effectively disable limit positions
        uint24 limitWidth = 887272;

        // Do rebalance based on current state using strategy
        // Use address(0) to default to UniformStrategy
        if (basePositionsLength == 0) {
            mpm.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(0), // Will use default UniformStrategy
                    center: currentTick, // centerTick
                    tLeft: 1000, // ticksLeft
                    tRight: 1000, // ticksRight
                    limitWidth: limitWidth,
                    weight0: 0.5e18,
                    weight1: 0.5e18,
                    useCarpet: false // useCarpet
                }),
                new uint256[2][](0), // empty outMin
                new uint256[2][](0) // empty inMin
            );
        } else {
            mpm.rebalance(
                IMultiPositionManager.RebalanceParams({
                    strategy: address(0), // Will use default UniformStrategy
                    center: currentTick, // centerTick
                    tLeft: 1000, // ticksLeft
                    tRight: 1000, // ticksRight
                    limitWidth: limitWidth,
                    weight0: 0.5e18,
                    weight1: 0.5e18,
                    useCarpet: false // useCarpet
                }),
                new uint256[2][](basePositionsLength),
                new uint256[2][](0) // empty inMin
            );
        }
    }

    function run(
        address payable _multiPositionManager,
        uint256 _deposit0,
        uint256 _deposit1,
        address _uniproxy,
        address _admin,
        address _poolManager,
        uint24 fee,
        int24 tickSpacing,
        address _hook
    ) public {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("Initializing");

        // Get MPM
        MultiPositionManager mpm = MultiPositionManager(_multiPositionManager);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Get pool key to access token addresses
        PoolKey memory poolKey = mpm.poolKey();
        address token0Address = Currency.unwrap(poolKey.currency0);
        address token1Address = Currency.unwrap(poolKey.currency1);

        // Approve and setup whitelist
        if (token0Address != address(0) && _deposit0 > 0) {
            IERC20(token0Address).approve(_multiPositionManager, _deposit0);
        }
        if (_deposit1 > 0) {
            IERC20(token1Address).approve(_multiPositionManager, _deposit1);
        }

        // Make deposit
        mpm.deposit{value: token0Address == address(0) ? _deposit0 : 0}(_deposit0, _deposit1, deployer, deployer);

        // Setup position and do rebalance using helper function
        setupPosition(mpm, poolKey, _deposit0, _deposit1, _poolManager);

        // Transfer ownership to admin
        mpm.transferOwnership(_admin);

        vm.stopBroadcast();
    }
}
