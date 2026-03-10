/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {RebalanceLogic} from "../libraries/RebalanceLogic.sol";

interface IMultiPositionManager is IERC20, IImmutableState {
    enum Action {
        WITHDRAW,
        REBALANCE,
        ZERO_BURN,
        CLAIM_FEE,
        BURN_ALL,
        COMPOUND
    }

    struct Range {
        int24 lowerTick;
        int24 upperTick;
    }

    // @deprecated Use Range instead - Position included redundant poolKey
    struct Position {
        PoolKey poolKey;
        int24 lowerTick;
        int24 upperTick;
    }

    struct PositionData {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    struct RebalanceParams {
        address strategy;
        int24 center;
        uint24 tLeft;
        uint24 tRight;
        uint24 limitWidth;
        uint256 weight0;
        uint256 weight1;
        bool useCarpet; // Use full-range floor
    }

    struct RebalanceSwapParams {
        RebalanceParams rebalanceParams;
        RebalanceLogic.SwapParams swapParams;
    }

    event Rebalance(Range[] ranges, PositionData[] positionData, RebalanceParams params);

    event Deposit(address indexed from, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);

    function getPositions() external view returns (Range[] memory, PositionData[] memory);
    function getBasePositions() external view returns (Range[] memory, PositionData[] memory);
    function poolKey() external view returns (PoolKey memory);
    function fee() external view returns (uint16);
    function factory() external view returns (address);
    function basePositionsLength() external view returns (uint256);
    function limitPositionsLength() external view returns (uint256);
    function limitPositions(uint256 index) external view returns (Range memory);
    function getTotalAmounts()
        external
        view
        returns (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1);
    function currentTick() external view returns (int24);
    function rebalance(RebalanceParams calldata params, uint256[2][] memory outMin, uint256[2][] memory inMin)
        external
        payable;
    function rebalanceSwap(RebalanceSwapParams calldata params, uint256[2][] memory outMin, uint256[2][] memory inMin)
        external
        payable;
    function claimFee() external;
    function setFee(uint16 fee) external;
    // function setTickOffset(uint24 offset) external;
    function deposit(uint256 deposit0Desired, uint256 deposit1Desired, address to, address from)
        external
        payable
        returns (uint256, uint256, uint256);

    function compound(uint256[2][] calldata inMin) external payable;

    function compoundSwap(RebalanceLogic.SwapParams calldata swapParams, uint256[2][] calldata inMin)
        external
        payable;
    function withdraw(uint256 shares, uint256[2][] memory outMin, bool withdrawToWallet)
        external
        returns (uint256 amount0, uint256 amount1);
    function withdrawCustom(uint256 amount0Desired, uint256 amount1Desired, uint256[2][] memory outMin)
        external
        returns (uint256 amount0Out, uint256 amount1Out, uint256 sharesBurned);

    // Role management functions
    function grantRelayerRole(address account) external;
    function revokeRelayerRole(address account) external;
    function isRelayer(address account) external view returns (bool);

    // Ratio functions
    function getRatios()
        external
        view
        returns (
            uint256 pool0Ratio,
            uint256 pool1Ratio,
            uint256 total0Ratio,
            uint256 total1Ratio,
            uint256 inPositionRatio,
            uint256 outOfPositionRatio,
            uint256 baseRatio,
            uint256 limitRatio,
            uint256 base0Ratio,
            uint256 base1Ratio,
            uint256 limit0Ratio,
            uint256 limit1Ratio
        );

    // Strategy parameters
    function lastStrategyParams()
        external
        view
        returns (
            address strategy,
            int24 centerTick,
            uint24 ticksLeft,
            uint24 ticksRight,
            uint24 limitWidth,
            uint120 weight0,
            uint120 weight1,
            bool useCarpet,
            bool useSwap,
            bool useAssetWeights
        );
}
