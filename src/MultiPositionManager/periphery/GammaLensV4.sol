// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MultiPositionManager} from "../MultiPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

interface ERC20MinimalInterface {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/**
 * @notice Common struct for pool information across all pool types
 */
struct PoolInfoUniV3 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint8 feeProtocol; // uint8 for UniV3
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint24 fee; // Pool trading fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

struct PoolInfoKodiakV3 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint32 feeProtocol; // uint32 for Kodiak
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint24 fee; // Pool trading fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

struct PoolInfoAlgebraV1 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint8 communityFeeToken0;
    uint8 communityFeeToken1;
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint16 fee; // uint16 for Algebra V1
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128; // totalFeeGrowth0Token
    uint256 feeGrowthGlobal1X128; // totalFeeGrowth1Token
}

struct PoolInfoAlgebraV11 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint16 communityFeeToken0; // uint16 in V1.1
    uint16 communityFeeToken1; // uint16 in V1.1
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint16 fee; // uint16 for Algebra V1.1
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128; // totalFeeGrowth0Token
    uint256 feeGrowthGlobal1X128; // totalFeeGrowth1Token
}

struct PoolInfoAlgebraV12 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint8 communityFeeToken0;
    uint8 communityFeeToken1;
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint16 feeZto; // Zero to one fee
    uint16 feeOtz; // One to zero fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128; // totalFeeGrowth0Token
    uint256 feeGrowthGlobal1X128; // totalFeeGrowth1Token
}

struct PoolInfoAlgebraIntegral {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint16 communityFee; // Single community fee
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint16 lastFee; // lastFee instead of fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128; // totalFeeGrowth0Token
    uint256 feeGrowthGlobal1X128; // totalFeeGrowth1Token
}

struct PoolInfoUniV4 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint24 feeProtocol;
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint24 fee; // Pool trading fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

struct PoolInfoRamsesV2 {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint8 feeProtocol;
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint24 fee;
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

/**
 * @notice Interface for Uniswap V3 Pool with tick information
 */
interface IUniswapV3Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for Kodiak V3 Pool with tick information
 */
interface IKodiakV3Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for Algebra V1 Pool with tick information
 */
interface IAlgebraV1Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 fee,
            uint16 timepointIndex,
            uint8 communityFeeToken0,
            uint8 communityFeeToken1,
            bool unlocked
        );

    function totalFeeGrowth0Token() external view returns (uint256);
    function totalFeeGrowth1Token() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for Algebra V1.1 Pool with tick information
 */
interface IAlgebraV11Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 fee,
            uint16 timepointIndex,
            uint16 communityFeeToken0,
            uint16 communityFeeToken1,
            bool unlocked
        );

    function totalFeeGrowth0Token() external view returns (uint256);
    function totalFeeGrowth1Token() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for Algebra V1.2 Pool with tick information
 */
interface IAlgebraV12Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function globalState()
        external
        view
        returns (
            uint160 price,
            int24 tick,
            uint16 feeZto,
            uint16 feeOtz,
            uint16 timepointIndex,
            uint8 communityFeeToken0,
            uint8 communityFeeToken1,
            bool unlocked
        );

    function totalFeeGrowth0Token() external view returns (uint256);
    function totalFeeGrowth1Token() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for Algebra Integral Pool with tick information
 */
interface IAlgebraIntegralPool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint256 liquidityTotal,
            int128 liquidityDelta,
            int24 prevTick,
            int24 nextTick,
            uint256 outerFeeGrowth0Token,
            uint256 outerFeeGrowth1Token
        );

    function globalState()
        external
        view
        returns (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16 communityFee, bool unlocked);

    function totalFeeGrowth0Token() external view returns (uint256);
    function totalFeeGrowth1Token() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for RamsesV2 Pool with tick information
 */
interface IRamsesV2Pool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint128 boostedLiquidityGross,
            int128 boostedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

/**
 * @notice Interface for CLPool with tick information
 */
interface ICLPool {
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            int128 stakedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            uint256 rewardGrowthOutsideX128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function unstakedFee() external view returns (uint24);
}

struct PoolInfoCLPool {
    // Slot0/GlobalState fields
    uint160 sqrtPriceX96;
    int24 tick;
    uint24 unstakedFee;
    // Additional pool info
    int24 tickSpacing;
    uint128 liquidity;
    uint24 fee; // Pool trading fee
    // Token info
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    // Fee growth
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
}

/**
 * @title GammaLensV2
 * @notice A contract that provides view functions for MultiPositionManager statistics
 */
contract GammaLensV3 is Initializable, OwnableUpgradeable {
    // Precision constant for fixed-point calculations
    uint256 public constant PRECISION = 10e18;

    struct PositionStats {
        // Tick range
        int24 tickLower;
        int24 tickUpper;
        // Price range (token0/token1) in sqrtX96 format
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        // Token quantities and value
        uint256 token0Quantity;
        uint256 token1Quantity;
        uint256 valueInToken1;
    }

    struct PositionStatsComprehensive {
        // Tick range
        int24 tickLower;
        int24 tickUpper;
        // Price range (token0/token1) in sqrtX96 format
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        // Token quantities and value
        uint256 token0Quantity;
        uint256 token1Quantity;
        uint256 valueInToken1;
        // Additional comprehensive data
        uint128 liquidity;
        int24 currentTick;
        PoolKey poolKey;
        PoolId poolId;
        address poolManager;
        // Current price data
        uint160 sqrtPrice;
        uint24 protocolFee;
        uint24 lpFee;
        string token0Symbol;
        string token1Symbol;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    /**
     * @notice Struct to store tick information
     */
    struct TickInfo {
        int24 tick;
        uint128 liquidityGross;
        int128 liquidityNet;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Get detailed statistics for all positions in a MultiPositionManager
     * @param manager The MultiPositionManager contract to query
     * @return stats Array of statistics for each position
     */
    function getPositionStats(MultiPositionManager manager) public view returns (PositionStats[] memory stats) {
        // Get positions from the manager
        (MultiPositionManager.Range[] memory ranges, MultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        stats = new PositionStats[](ranges.length);

        // Process each position
        for (uint256 i = 0; i < ranges.length; i++) {
            MultiPositionManager.Range memory range = ranges[i];

            // Skip invalid positions (with zero boundaries)
            if (range.lowerTick == 0 && range.upperTick == 0) {
                continue;
            }

            // Get the current sqrt price from the pool using StateLibrary
            (uint160 sqrtPriceX96,,,) =
                StateLibrary.getSlot0(IPoolManager(address(manager.poolManager())), manager.poolKey().toId());

            // Get sqrt prices at tick boundaries
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(range.lowerTick);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(range.upperTick);

            // Get token quantities from liquidity
            (uint256 token0Quantity, uint256 token1Quantity) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(positionData[i].liquidity)
            );

            // Calculate value in token1 (token0 * price + token1)
            uint256 token0ValueInToken1 =
                FullMath.mulDiv(token0Quantity, uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1 << 192);
            uint256 valueInToken1 = token0ValueInToken1 + token1Quantity;

            // Store the stats
            stats[i] = PositionStats({
                tickLower: range.lowerTick,
                tickUpper: range.upperTick,
                sqrtPriceLower: sqrtPriceLowerX96,
                sqrtPriceUpper: sqrtPriceUpperX96,
                token0Quantity: token0Quantity,
                token1Quantity: token1Quantity,
                valueInToken1: valueInToken1
            });
        }
    }

    /**
     * @notice Get comprehensive statistics for all positions in a MultiPositionManager
     * @param manager The MultiPositionManager contract to query
     * @return stats Array of comprehensive statistics for each position
     */
    function getPositionStatsComprehensive(MultiPositionManager manager)
        public
        view
        returns (PositionStatsComprehensive[] memory stats)
    {
        // Get positions from the manager
        (MultiPositionManager.Range[] memory ranges, MultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        stats = new PositionStatsComprehensive[](ranges.length);
        IPoolManager poolManager = IPoolManager(address(manager.poolManager()));

        // Process each position
        for (uint256 i = 0; i < ranges.length; i++) {
            // Skip invalid positions (with zero boundaries)
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) {
                continue;
            }

            // Calculate comprehensive stats for this position
            stats[i] = _calculatePositionStatsComprehensive(poolManager, manager, ranges[i], positionData[i].liquidity);
        }
    }

    /**
     * @notice Internal helper to calculate comprehensive stats for a single position
     * @param poolManager The pool manager contract
     * @param manager The MultiPositionManager contract
     * @param range The range to calculate stats for
     * @param liquidity The liquidity amount for the position
     * @return stats The comprehensive statistics for the position
     */
    function _calculatePositionStatsComprehensive(
        IPoolManager poolManager,
        MultiPositionManager manager,
        MultiPositionManager.Range memory range,
        uint256 liquidity
    ) internal view returns (PositionStatsComprehensive memory stats) {
        // Get poolKey from manager
        PoolKey memory poolKey = manager.poolKey();

        // Initialize the stats structure
        stats.tickLower = range.lowerTick;
        stats.tickUpper = range.upperTick;
        stats.poolKey = poolKey;
        stats.poolId = poolKey.toId();
        stats.poolManager = address(poolManager);
        stats.liquidity = uint128(liquidity);

        // Get the current sqrtPrice, tick, and fees from the pool using StateLibrary
        (stats.sqrtPrice, stats.currentTick, stats.protocolFee, stats.lpFee) =
            StateLibrary.getSlot0(poolManager, poolKey.toId());

        // Get sqrt prices at tick boundaries
        stats.sqrtPriceLower = TickMath.getSqrtPriceAtTick(range.lowerTick);
        stats.sqrtPriceUpper = TickMath.getSqrtPriceAtTick(range.upperTick);

        // Get token quantities from liquidity
        (stats.token0Quantity, stats.token1Quantity) = LiquidityAmounts.getAmountsForLiquidity(
            stats.sqrtPrice, stats.sqrtPriceLower, stats.sqrtPriceUpper, uint128(liquidity)
        );

        // Calculate value in token1 (token0 * price + token1)
        uint256 token0ValueInToken1 =
            FullMath.mulDiv(stats.token0Quantity, uint256(stats.sqrtPrice) * uint256(stats.sqrtPrice), 1 << 192);
        stats.valueInToken1 = token0ValueInToken1 + stats.token1Quantity;

        // Add token information
        _addTokenInfo(stats, manager);
    }

    /**
     * @notice Helper function to add token information to a stats struct
     * @param stats The stats struct to update
     * @param manager The MultiPositionManager contract
     */
    function _addTokenInfo(PositionStatsComprehensive memory stats, MultiPositionManager manager) internal view {
        // Get token addresses
        address token0Address = Currency.unwrap(manager.poolKey().currency0);
        address token1Address = Currency.unwrap(manager.poolKey().currency1);

        // For token0, check if it's the native token
        if (token0Address == address(0)) {
            stats.token0Symbol = "NATIVE";
            stats.token0Decimals = 18;
        } else {
            // Get symbol and decimals from ERC20 token
            IERC20Metadata token0 = IERC20Metadata(token0Address);
            stats.token0Symbol = token0.symbol();
            stats.token0Decimals = token0.decimals();
        }

        // For token1, always get from the token contract
        IERC20Metadata token1 = IERC20Metadata(token1Address);
        stats.token1Symbol = token1.symbol();
        stats.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get tick information for a range around the current tick
     * @param poolManager Pool manager contract
     * @param poolKey of the pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoUniV4(IPoolManager poolManager, PoolKey memory poolKey, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and calculate aligned tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, poolKey.tickSpacing, numTicks);

        // Create array and iterate through ticks
        tickInfos = new TickInfo[](totalTicks);

        for (uint256 i = 0; i < tickInfos.length; i++) {
            int24 tick = startTick + int24(uint24(i)) * poolKey.tickSpacing;
            (
                uint128 liquidityGross,
                int128 liquidityNet,
                , // feeGrowthOutside0X128 (not needed)
                    // feeGrowthOutside1X128 (not needed)
            ) = StateLibrary.getTickInfo(poolManager, poolKey.toId(), tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Uniswap V3 pool
     * @param pool Uniswap V3 pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoUniV3(IUniswapV3Pool pool, uint24 numTicks) public view returns (TickInfo[] memory tickInfos) {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint128 liquidityGross, int128 liquidityNet,,,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Kodiak V3 pool
     * @param pool Kodiak V3 pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoKodiakV3(IKodiakV3Pool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint128 liquidityGross, int128 liquidityNet,,,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Algebra V1 pool
     * @param pool Algebra V1 pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoAlgebraV1(IAlgebraV1Pool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint128 liquidityGross, int128 liquidityNet,,,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Algebra V1.1 pool
     * @param pool Algebra V1.1 pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoAlgebraV11(IAlgebraV11Pool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint128 liquidityGross, int128 liquidityNet,,,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Algebra V1.2 pool
     * @param pool Algebra V1.2 pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoAlgebraV12(IAlgebraV12Pool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint128 liquidityGross, int128 liquidityNet,,,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get tick information for a range around the current tick in Algebra Integral pool
     * @param pool Algebra Integral pool
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoAlgebraIntegral(IAlgebraIntegralPool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,) = pool.globalState();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (uint256 liquidityGross, int128 liquidityNet,,,,) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: uint128(liquidityGross), liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get total value of all positions in a MultiPositionManager
     * @param manager The MultiPositionManager contract
     * @return totalToken0 Total amount of token0 across all positions
     * @return totalToken1 Total amount of token1 across all positions
     * @return totalValueInToken1 Total value in terms of token1
     */
    function getTotalValueInPosition(MultiPositionManager manager)
        public
        view
        returns (uint256 totalToken0, uint256 totalToken1, uint256 totalValueInToken1)
    {
        PositionStats[] memory allStats = getPositionStats(manager);

        for (uint256 i = 0; i < allStats.length; i++) {
            totalToken0 += allStats[i].token0Quantity;
            totalToken1 += allStats[i].token1Quantity;
            totalValueInToken1 += allStats[i].valueInToken1;
        }
    }

    /**
     * @notice Get total token amounts, fees, and liquidity from the MultiPositionManager
     * @param manager The MultiPositionManager contract
     * @return total0 Total amount of token0
     * @return total1 Total amount of token1
     * @return totalFee0 Total fee in token0
     * @return totalFee1 Total fee in token1
     * @return totalLiquidity Total liquidity across all positions
     */
    function getTotalValues(MultiPositionManager manager)
        public
        view
        returns (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1, uint128 totalLiquidity)
    {
        // Get token amounts and fees from MultiPositionManager
        (total0, total1, totalFee0, totalFee1) = manager.getTotalAmounts();

        // Calculate total liquidity across all positions
        (MultiPositionManager.Range[] memory ranges, MultiPositionManager.PositionData[] memory positionData) =
            manager.getPositions();

        for (uint256 i = 0; i < ranges.length; i++) {
            // Skip invalid positions
            if (ranges[i].lowerTick == 0 && ranges[i].upperTick == 0) {
                continue;
            }

            totalLiquidity += uint128(positionData[i].liquidity);
        }
    }

    /**
     * @notice Convert a sqrt price (in X96 format) to a price value
     * @param sqrtPriceX96 The sqrt price in X96 format
     * @return price The actual price value (token1/token0) scaled by PRECISION
     */
    function getPriceFromSqrtPrice(uint160 sqrtPriceX96) public pure returns (uint256 price) {
        // Price = (sqrtPrice)² / 2^192 * PRECISION
        return FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), PRECISION, 1 << 192);
    }

    /**
     * @notice Convert a tick value to a price value
     * @param tick The tick value
     * @return price The actual price value (token1/token0) scaled by PRECISION
     */
    function getPriceFromTick(int24 tick) public pure returns (uint256 price) {
        // First get the sqrtPrice from the tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        // Then convert sqrtPrice to price using getPriceFromSqrtPrice
        return getPriceFromSqrtPrice(sqrtPriceX96);
    }

    /**
     * @notice Get comprehensive pool information for a Uniswap V3 pool
     * @param pool Uniswap V3 pool address
     * @return info Pool information
     */
    function getPoolInfoUniV3(IUniswapV3Pool pool) public view returns (PoolInfoUniV3 memory info) {
        // Get slot0 data
        (
            info.sqrtPriceX96,
            info.tick,
            , // observationIndex (not needed)
            , // observationCardinality (not needed)
            , // observationCardinalityNext (not needed)
            info.feeProtocol, // Need trailing comma to skip unlocked
                // unlocked not needed
        ) = pool.slot0();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();
        info.fee = pool.fee();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        info.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for a Kodiak V3 pool
     * @param pool Kodiak V3 pool address
     * @return info Pool information
     */
    function getPoolInfoKodiakV3(IKodiakV3Pool pool) public view returns (PoolInfoKodiakV3 memory info) {
        // Get slot0 data
        (
            info.sqrtPriceX96,
            info.tick,
            , // observationIndex (not needed)
            , // observationCardinality (not needed)
            , // observationCardinalityNext (not needed)
            info.feeProtocol,
            // unlocked not needed
        ) = pool.slot0();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();
        info.fee = pool.fee();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        info.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for a Uniswap V4 pool
     * @param poolManager The pool manager contract
     * @param poolKey The pool key containing pool parameters and tokens
     * @return info Pool information
     */
    function getPoolInfoUniV4(IPoolManager poolManager, PoolKey memory poolKey)
        public
        view
        returns (PoolInfoUniV4 memory info)
    {
        // Get pool ID from key
        PoolId poolId = poolKey.toId();

        // Get slot0 data
        (
            info.sqrtPriceX96,
            info.tick,
            info.feeProtocol, // already uint24
            info.fee // already uint24
        ) = StateLibrary.getSlot0(poolManager, poolId);

        // Get liquidity
        info.liquidity = StateLibrary.getLiquidity(poolManager, poolId);

        // Get fee growth
        (info.feeGrowthGlobal0X128, info.feeGrowthGlobal1X128) = StateLibrary.getFeeGrowthGlobals(poolManager, poolId);

        // Get token info directly from poolKey currencies
        address token0Address = Currency.unwrap(poolKey.currency0);
        address token1Address = Currency.unwrap(poolKey.currency1);

        // Handle native token for token0 only (token1 is never native)
        if (token0Address == address(0)) {
            info.token0Symbol = "NATIVE";
            info.token0Decimals = 18;
        } else {
            ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
            info.token0Symbol = token0.symbol();
            info.token0Decimals = token0.decimals();
        }

        // Token1 is always non-native
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);
        info.token1Symbol = token1.symbol();
        info.token1Decimals = token1.decimals();

        // Get tick spacing directly from pool key
        info.tickSpacing = poolKey.tickSpacing;
    }

    /**
     * @notice Get comprehensive pool information for an Algebra V1 pool
     * @param pool Algebra V1 pool address
     * @return info Pool information
     */
    function getPoolInfoAlgebraV1(IAlgebraV1Pool pool) public view returns (PoolInfoAlgebraV1 memory info) {
        // Get globalState data
        (
            info.sqrtPriceX96,
            info.tick,
            info.fee,
            , // timepointIndex not needed
            info.communityFeeToken0,
            info.communityFeeToken1,
            // unlocked not needed
        ) = pool.globalState();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        info.feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for an Algebra V1.1 pool
     * @param pool Algebra V1.1 pool address
     * @return info Pool information
     */
    function getPoolInfoAlgebraV11(IAlgebraV11Pool pool) public view returns (PoolInfoAlgebraV11 memory info) {
        // Get globalState data
        (
            info.sqrtPriceX96,
            info.tick,
            info.fee,
            , // timepointIndex not needed
            info.communityFeeToken0,
            info.communityFeeToken1,
            // unlocked not needed
        ) = pool.globalState();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        info.feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for an Algebra V1.2 pool
     * @param pool Algebra V1.2 pool address
     * @return info Pool information
     */
    function getPoolInfoAlgebraV12(IAlgebraV12Pool pool) public view returns (PoolInfoAlgebraV12 memory info) {
        // Get globalState data
        (
            info.sqrtPriceX96,
            info.tick,
            info.feeZto,
            info.feeOtz,
            , // timepointIndex not needed
            info.communityFeeToken0,
            info.communityFeeToken1,
            // unlocked not needed
        ) = pool.globalState();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        info.feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for an Algebra Integral pool
     * @param pool Algebra Integral pool address
     * @return info Pool information
     */
    function getPoolInfoAlgebraIntegral(IAlgebraIntegralPool pool)
        public
        view
        returns (PoolInfoAlgebraIntegral memory info)
    {
        // Get globalState data
        (
            info.sqrtPriceX96,
            info.tick,
            info.lastFee,
            , // pluginConfig not needed
            info.communityFee,
            // unlocked not needed
        ) = pool.globalState();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.totalFeeGrowth0Token();
        info.feeGrowthGlobal1X128 = pool.totalFeeGrowth1Token();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get comprehensive pool information for a RamsesV2 pool
     * @param pool RamsesV2 pool address
     * @return info Pool information
     */
    function getPoolInfoRamsesV2(IRamsesV2Pool pool) public view returns (PoolInfoRamsesV2 memory info) {
        // Get slot0 data
        (
            info.sqrtPriceX96,
            info.tick,
            , // observationIndex (not needed)
            , // observationCardinality (not needed)
            , // observationCardinalityNext (not needed)
            info.feeProtocol,
            // unlocked not needed
        ) = pool.slot0();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();
        info.fee = pool.fee();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        info.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get tick information for a range around the current tick in RamsesV2 pool
     * @param pool RamsesV2 pool address
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoRamsesV2(IRamsesV2Pool pool, uint24 numTicks)
        public
        view
        returns (TickInfo[] memory tickInfos)
    {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (
                uint128 liquidityGross,
                int128 liquidityNet,
                , // boostedLiquidityGross not needed
                , // boostedLiquidityNet not needed
                , // feeGrowthOutside0X128 not needed
                , // feeGrowthOutside1X128 not needed
                , // tickCumulativeOutside not needed
                , // secondsPerLiquidityOutsideX128 not needed
                , // secondsOutside not needed
                    // initialized not needed
            ) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    /**
     * @notice Get comprehensive pool information for a CLPool
     * @param pool CLPool address
     * @return info Pool information
     */
    function getPoolInfoCLPool(ICLPool pool) public view returns (PoolInfoCLPool memory info) {
        // Get slot0 data
        (
            info.sqrtPriceX96,
            info.tick,
            , // observationIndex (not needed)
            , // observationCardinality (not needed)
            , // observationCardinalityNext (not needed)
                // unlocked not needed
        ) = pool.slot0();

        // Get additional pool info
        info.tickSpacing = pool.tickSpacing();
        info.liquidity = pool.liquidity();
        info.fee = pool.fee();
        info.unstakedFee = pool.unstakedFee();

        // Get fee growth
        info.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        info.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        // Get token info
        address token0Address = pool.token0();
        address token1Address = pool.token1();

        ERC20MinimalInterface token0 = ERC20MinimalInterface(token0Address);
        ERC20MinimalInterface token1 = ERC20MinimalInterface(token1Address);

        info.token0Symbol = token0.symbol();
        info.token1Symbol = token1.symbol();
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /**
     * @notice Get tick information for a range around the current tick in CLPool
     * @param pool CLPool address
     * @param numTicks Number of ticks to include on each side of the current tick
     * @return tickInfos Array of tick information
     */
    function getTickInfoCLPool(ICLPool pool, uint24 numTicks) public view returns (TickInfo[] memory tickInfos) {
        // Get current tick and tick spacing from pool
        (, int24 currentTick,,,,) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();

        // Use the helper function to calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(currentTick, tickSpacing, numTicks);

        tickInfos = new TickInfo[](totalTicks);

        // Iterate through ticks
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i)) * tickSpacing;

            (
                uint128 liquidityGross,
                int128 liquidityNet,
                , // stakedLiquidityNet not needed
                , // feeGrowthOutside0X128 not needed
                , // feeGrowthOutside1X128 not needed
                , // rewardGrowthOutsideX128 not needed
                , // tickCumulativeOutside not needed
                , // secondsPerLiquidityOutsideX128 not needed
                , // secondsOutside not needed
                    // initialized not needed
            ) = pool.ticks(tick);

            tickInfos[i] = TickInfo({tick: tick, liquidityGross: liquidityGross, liquidityNet: liquidityNet});
        }
    }

    // Create a generic function for the tick calculation logic that appears in all getTickInfo functions
    function _calculateTickRange(int24 currentTick, int24 tickSpacing, uint24 numTicks)
        internal
        pure
        returns (int24 startTick, uint256 totalTicks)
    {
        int24 alignedTick = (currentTick / tickSpacing) * tickSpacing;
        startTick = alignedTick - int24(numTicks);
        int24 endTick = alignedTick + int24(numTicks);

        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (startTick < minTick) startTick = minTick;
        if (endTick > maxTick) endTick = maxTick;

        totalTicks = (uint24(endTick - startTick) / uint24(tickSpacing)) + 1;
    }
}
