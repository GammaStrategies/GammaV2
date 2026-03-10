// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "forge-std/console.sol";
import "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract TestCarpetWithdrawSingleToken is TestMultiPositionManager {
    function setUp() public override {
        super.setUp();
    }

    function test_CarpetRebalanceFallsBackWithInsufficientLiquidity() public {
        console.log("\n=== Testing Carpet Rebalance With Insufficient Liquidity ===");

        uint256 amount0 = 10;
        uint256 amount1 = 10;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        console.log("Deposited tiny amount - token0:", amount0);
        console.log("Deposited tiny amount - token1:", amount1);

        IMultiPositionManager.RebalanceParams memory paramsCarpet1 = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true
        });

        (uint256[2][] memory outMinCarpet1, uint256[2][] memory inMinCarpet1) = SimpleLensInMin
            .getOutMinAndInMinForRebalance(
            multiPositionManager,
            paramsCarpet1.strategy,
            paramsCarpet1.center,
            paramsCarpet1.tLeft,
            paramsCarpet1.tRight,
            paramsCarpet1.limitWidth,
            paramsCarpet1.weight0,
            paramsCarpet1.weight1,
            paramsCarpet1.useCarpet,
            false, // swap
            500, 500 // 5% slippage
        );

        multiPositionManager.rebalance(paramsCarpet1, outMinCarpet1, inMinCarpet1);

        uint256 baseLength = multiPositionManager.basePositionsLength();
        assertTrue(baseLength > 0, "Fallback rebalance produced no base positions");
        console.log("Fallback rebalance succeeded with non-carpet ranges");

        vm.stopPrank();
    }

    // function test_CarpetRebalanceRevertsAfterFullToken0Withdrawal() public {
    //     console.log("\n=== Testing Carpet Rebalance After Full Token0 Withdrawal ===");

    //     uint256 amount0 = 100e18;
    //     uint256 amount1 = 100e18;

    //     vm.startPrank(owner);
    //     token0.mint(owner, amount0);
    //     token1.mint(owner, amount1);
    //     token0.approve(address(multiPositionManager), amount0);
    //     token1.approve(address(multiPositionManager), amount1);

    //     multiPositionManager.deposit(amount0, amount1, owner, owner);

    //     console.log("Deposited token0:", amount0 / 1e18);
    //     console.log("Deposited token1:", amount1 / 1e18);

    //     IMultiPositionManager.RebalanceParams memory paramsCarpet2 = IMultiPositionManager.RebalanceParams({
    //         strategy: address(exponentialStrategy),
    //         center: 0,
    //         tLeft: 1800,
    //         tRight: 1800,
    //         limitWidth: 60,
    //         weight0: 0.5e18,
    //         weight1: 0.5e18,
    //         useCarpet: true
    //     });

    //     (uint256[2][] memory outMinCarpet2, uint256[2][] memory inMinCarpet2) = lens.getOutMinAndInMinForRebalance(
    //         address(multiPositionManager),
    //         paramsCarpet2.strategy,
    //         paramsCarpet2.center,
    //         paramsCarpet2.tLeft,
    //         paramsCarpet2.tRight,
    //         paramsCarpet2.limitWidth,
    //         paramsCarpet2.weight0,
    //         paramsCarpet2.weight1,
    //         paramsCarpet2.useCarpet,
    //         false,  // swap
    //         500  // 5% slippage
    //     );

    //     multiPositionManager.rebalance(paramsCarpet2, outMinCarpet2, inMinCarpet2);

    //     console.log("Rebalanced with carpet mode");

    //     (uint256 total0Before, uint256 total1Before, , ) = multiPositionManager.getTotalAmounts();
    //     console.log("Before withdrawal - Token0:", total0Before / 1e18);
    //     console.log("Before withdrawal - Token1:", total1Before / 1e18);

    //     uint256 baseLen = multiPositionManager.basePositionsLength();
    //     uint256 limitLen = multiPositionManager.limitPositionsLength();
    //     uint256[2][] memory outMin = new uint256[2][](baseLen + limitLen);

    //     vm.expectRevert(MultiPositionManager.CarpetRequiresBothTokens.selector);
    //     multiPositionManager.withdrawCustom(
    //         total0Before,  // amount0Desired
    //         0,             // amount1Desired
    //         owner,
    //         outMin
    //     );

    //     console.log("Correctly reverted on carpet rebalance with only token1");

    //     vm.stopPrank();
    // }

    // function test_CarpetRebalanceWithDustAmount() public {
    //     console.log("\n=== Testing Carpet Rebalance With Dust Token0 ===");

    //     uint256 amount0 = 100e18;
    //     uint256 amount1 = 100e18;

    //     vm.startPrank(owner);
    //     token0.mint(owner, amount0);
    //     token1.mint(owner, amount1);
    //     token0.approve(address(multiPositionManager), amount0);
    //     token1.approve(address(multiPositionManager), amount1);

    //     multiPositionManager.deposit(amount0, amount1, owner, owner);

    //     IMultiPositionManager.RebalanceParams memory paramsCarpet3 = IMultiPositionManager.RebalanceParams({
    //         strategy: address(exponentialStrategy),
    //         center: 0,
    //         tLeft: 1800,
    //         tRight: 1800,
    //         limitWidth: 60,
    //         weight0: 0.5e18,
    //         weight1: 0.5e18,
    //         useCarpet: true
    //     });

    //     (uint256[2][] memory outMinCarpet3, uint256[2][] memory inMinCarpet3) = lens.getOutMinAndInMinForRebalance(
    //         address(multiPositionManager),
    //         paramsCarpet3.strategy,
    //         paramsCarpet3.center,
    //         paramsCarpet3.tLeft,
    //         paramsCarpet3.tRight,
    //         paramsCarpet3.limitWidth,
    //         paramsCarpet3.weight0,
    //         paramsCarpet3.weight1,
    //         paramsCarpet3.useCarpet,
    //         false,  // swap
    //         500  // 5% slippage
    //     );

    //     multiPositionManager.rebalance(paramsCarpet3, outMinCarpet3, inMinCarpet3);

    //     console.log("Rebalanced with carpet mode");

    //     (uint256 total0Before, , , ) = multiPositionManager.getTotalAmounts();
    //     uint256 withdrawAmount = total0Before;
    //     console.log("Withdrawing token0:", withdrawAmount / 1e18);
    //     console.log("Leaving dust: 100 wei");

    //     uint256 baseLen = multiPositionManager.basePositionsLength();
    //     uint256 limitLen = multiPositionManager.limitPositionsLength();
    //     uint256[2][] memory outMin = new uint256[2][](baseLen + limitLen);

    //     // Withdrawal will trigger rebalance with carpet mode, which should fail due to insufficient liquidity (dust)
    //     vm.expectRevert(MultiPositionManager.InsufficientLiquidityForCarpet.selector);
    //     multiPositionManager.withdrawCustom(
    //         withdrawAmount,  // amount0Desired
    //         0,               // amount1Desired
    //         owner,
    //         outMin
    //     );

    //     console.log("Correctly reverted with InsufficientLiquidityForCarpet due to dust amount during withdrawal rebalance");

    //     vm.stopPrank();
    // }

    function test_WithdrawMaxSingleToken_CarpetStillExists() public {
        console.log("\n=== Testing Withdraw Max Single Token with Carpet Visualization ===");

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        uint256 baseLen = multiPositionManager.basePositionsLength();
        uint256 limitLen = multiPositionManager.limitPositionsLength();
        uint256[2][] memory outMin = new uint256[2][](baseLen + limitLen);

        IMultiPositionManager.RebalanceParams memory paramsCarpet6 = IMultiPositionManager.RebalanceParams({
            strategy: address(exponentialStrategy),
            center: 0,
            tLeft: 1800,
            tRight: 1800,
            limitWidth: 60,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: true
        });

        (, uint256[2][] memory inMinCarpet6) = SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            paramsCarpet6.strategy,
            paramsCarpet6.center,
            paramsCarpet6.tLeft,
            paramsCarpet6.tRight,
            paramsCarpet6.limitWidth,
            paramsCarpet6.weight0,
            paramsCarpet6.weight1,
            paramsCarpet6.useCarpet,
            false, // swap
            500, 500 // 5% slippage
        );

        multiPositionManager.rebalance(paramsCarpet6, outMin, inMinCarpet6);

        console.log("\n--- Before Withdrawal ---");
        _visualizePositions("Carpet Positions Before Withdrawal");

        (uint256 total0Before, uint256 total1Before,,) = multiPositionManager.getTotalAmounts();
        console.log("\nTotal before withdrawal:");
        console.log("  Token0:", total0Before);
        console.log("  Token1:", total1Before);

        _debugCarpetDetection();

        // Use total amounts for withdrawal test (no longer using getMaxWithdrawable)
        console.log("\nAttempting to withdraw total amounts:");
        console.log("  Token0:", total0Before);
        console.log("  Token1:", total1Before);

        baseLen = multiPositionManager.basePositionsLength();
        limitLen = multiPositionManager.limitPositionsLength();
        outMin = new uint256[2][](baseLen + limitLen);

        multiPositionManager.withdrawCustom(
            total0Before, // amount0Desired
            0, // amount1Desired
            outMin
        );

        console.log("\n--- After Withdrawal ---");
        _visualizePositions("Carpet Positions After Withdrawal");

        (IMultiPositionManager.Range[] memory ranges,) = multiPositionManager.getPositions();
        int24 minUsable = TickMath.minUsableTick(multiPositionManager.poolKey().tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(multiPositionManager.poolKey().tickSpacing);

        bool hasCarpetPositions = false;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].lowerTick == minUsable && ranges[i].upperTick == maxUsable) {
                hasCarpetPositions = true;
                break;
            }
        }

        assertTrue(hasCarpetPositions, "Full-range floor should still exist after max withdrawal");

        vm.stopPrank();
    }

    function _visualizePositions(string memory title) internal view override {
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        int24 currentTick = multiPositionManager.currentTick();
        uint256 baseCount = multiPositionManager.basePositionsLength();

        console.log(title);
        console.log(
            "Current Tick:", currentTick < 0 ? "-" : "", currentTick < 0 ? uint24(-currentTick) : uint24(currentTick)
        );
        console.log("Base Positions:", baseCount);
        if (positions.length > baseCount) {
            console.log("Limit Position: YES");
        }
        console.log("");

        uint128 maxLiquidity = _findMaxLiquidity(positionData);

        console.log("Liquidity Distribution Graph:");
        console.log("Legend: # = Token0, - = Token1, = = Both, C = Carpet");
        console.log("==============================");

        console.log("100% |");
        console.log(" 80% |");
        console.log(" 60% |");
        console.log(" 40% |");
        console.log(" 20% |");
        console.log("  0% +", _repeatChar("=", 80));
        console.log("     Tick Ranges:");

        _printPositions(positions, positionData, maxLiquidity, baseCount);

        console.log("");
        _printTotals(positionData);
        console.log("\n", _repeatChar("=", 80), "\n");
    }

    function _findMaxLiquidity(IMultiPositionManager.PositionData[] memory positionData)
        internal
        pure
        returns (uint128 maxLiquidity)
    {
        for (uint256 i = 0; i < positionData.length; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }
    }

    function _printPositions(
        IMultiPositionManager.Range[] memory positions,
        IMultiPositionManager.PositionData[] memory positionData,
        uint128 maxLiquidity,
        uint256 baseCount
    ) internal view {
        int24 minUsable = TickMath.minUsableTick(multiPositionManager.poolKey().tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(multiPositionManager.poolKey().tickSpacing);

        for (uint256 i = 0; i < positions.length; i++) {
            _printSinglePosition(positions[i], positionData[i], maxLiquidity, baseCount, i, minUsable, maxUsable);
        }
    }

    function _printSinglePosition(
        IMultiPositionManager.Range memory position,
        IMultiPositionManager.PositionData memory data,
        uint128 maxLiquidity,
        uint256 baseCount,
        uint256 index,
        int24 minUsable,
        int24 maxUsable
    ) internal pure {
        uint256 percentage = maxLiquidity > 0 ? (uint256(data.liquidity) * 100) / uint256(maxLiquidity) : 0;
        bool isCarpet = (position.lowerTick == minUsable && position.upperTick == maxUsable);

        string memory barChar = _getBarChar(data.amount0 > 0, data.amount1 > 0, isCarpet);
        string memory bar = _createBarWithChar(percentage, barChar);
        string memory posType = index < baseCount ? "Base" : "Limit";

        console.log(
            string(
                abi.encodePacked(
                    "  ",
                    posType,
                    " [",
                    _tickToString(position.lowerTick),
                    ",",
                    _tickToString(position.upperTick),
                    "]: ",
                    bar,
                    " (",
                    _uintToString(percentage),
                    "%)"
                )
            )
        );

        console.log(
            string(
                abi.encodePacked(
                    "       Token0: ",
                    _formatAmount(data.amount0),
                    " | Token1: ",
                    _formatAmount(data.amount1),
                    " | Liq: ",
                    _uintToString(uint256(data.liquidity))
                )
            )
        );
    }

    function _getBarChar(bool hasToken0, bool hasToken1, bool isCarpet) internal pure returns (string memory) {
        if (isCarpet) return "C";
        if (hasToken0 && hasToken1) return "=";
        if (hasToken0) return "#";
        return "-";
    }

    function _printTotals(IMultiPositionManager.PositionData[] memory positionData) internal pure {
        uint256 totalToken0 = 0;
        uint256 totalToken1 = 0;
        for (uint256 i = 0; i < positionData.length; i++) {
            totalToken0 += positionData[i].amount0;
            totalToken1 += positionData[i].amount1;
        }

        console.log("Total Liquidity Distribution:");
        console.log("  Total Token0:", _formatAmount(totalToken0));
        console.log("  Total Token1:", _formatAmount(totalToken1));
    }

    function _createBarWithChar(uint256 percentage, string memory char)
        internal
        pure
        override
        returns (string memory)
    {
        uint256 barLength = (percentage * 40) / 100;
        if (barLength == 0 && percentage > 0) barLength = 1;

        bytes memory charBytes = bytes(char);
        bytes memory bar = new bytes(barLength);
        for (uint256 i = 0; i < barLength; i++) {
            bar[i] = charBytes[0];
        }
        return string(bar);
    }

    function _repeatChar(string memory char, uint256 count) internal pure override returns (string memory) {
        bytes memory result = new bytes(count);
        bytes memory charBytes = bytes(char);
        for (uint256 i = 0; i < count; i++) {
            result[i] = charBytes[0];
        }
        return string(result);
    }

    function _tickToString(int24 tick) internal pure override returns (string memory) {
        if (tick < 0) {
            return string(abi.encodePacked("-", _uintToString(uint24(-tick))));
        }
        return _uintToString(uint24(tick));
    }

    function _uintToString(uint256 value) internal pure override returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _formatAmount(uint256 amount) internal pure override returns (string memory) {
        if (amount == 0) return "0";

        uint256 etherAmount = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e16;

        return
            string(abi.encodePacked(_uintToString(etherAmount), ".", decimal < 10 ? "0" : "", _uintToString(decimal)));
    }

    function _debugCarpetDetection() internal view {
        console.log("\n=== DEBUG: Carpet Detection ===");
        int24 minUsable = TickMath.minUsableTick(multiPositionManager.poolKey().tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(multiPositionManager.poolKey().tickSpacing);

        console.log("MinUsable:", minUsable < 0 ? "-" : "", minUsable < 0 ? uint24(-minUsable) : uint24(minUsable));
        console.log("MaxUsable:", maxUsable < 0 ? "-" : "", maxUsable < 0 ? uint24(-maxUsable) : uint24(maxUsable));

        (IMultiPositionManager.Range[] memory ranges, IMultiPositionManager.PositionData[] memory posData) =
            multiPositionManager.getPositions();

        uint256 carpetToken0 = 0;
        uint256 carpetToken1 = 0;

        for (uint256 i = 0; i < ranges.length; i++) {
            bool isCarpet = (ranges[i].lowerTick == minUsable && ranges[i].upperTick == maxUsable);
            if (isCarpet) {
                console.log("\nCarpet position found at index:", i);
                console.log("  Lower tick:", _tickToString(ranges[i].lowerTick));
                console.log("  Upper tick:", _tickToString(ranges[i].upperTick));
                console.log("  Amount0:", posData[i].amount0);
                console.log("  Amount1:", posData[i].amount1);
                carpetToken0 += posData[i].amount0;
                carpetToken1 += posData[i].amount1;
            }
        }

        console.log("\nTotal carpet amounts:");
        console.log("  Token0:", carpetToken0);
        console.log("  Token1:", carpetToken1);
        console.log("===============================\n");
    }
}
