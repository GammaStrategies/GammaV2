// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import {CamelStrategy} from "../src/MultiPositionManager/strategies/CamelStrategy.sol";

contract TestCamelDistribution is TestMultiPositionManager {
    CamelStrategy camelStrategy;

    function setUp() public override {
        super.setUp();
        camelStrategy = new CamelStrategy();
    }

    function test_CamelDoubleHumpDistribution() public {
        console.log("\n=== Testing Camel Double-Hump Distribution ===\n");

        // Deposit initial liquidity
        uint256 amount0 = 100 ether;
        uint256 amount1 = 100 ether;

        vm.startPrank(owner);
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Rebalance with Camel strategy
        IMultiPositionManager.RebalanceParams memory paramsCamel = IMultiPositionManager.RebalanceParams({
            strategy: address(camelStrategy),
            center: 0,
            tLeft: 1000,
            tRight: 1000,
            limitWidth: 0, // No limit positions for clarity
            weight0: 0.5e18, // 50/50 to see pure distribution
            weight1: 0.5e18,
            useCarpet: false
        });

        (uint256[2][] memory outMinCamel, uint256[2][] memory inMinCamel) =         SimpleLensInMin.getOutMinAndInMinForRebalance(
            multiPositionManager,
            paramsCamel.strategy,
            paramsCamel.center,
            paramsCamel.tLeft,
            paramsCamel.tRight,
            paramsCamel.limitWidth,
            paramsCamel.weight0,
            paramsCamel.weight1,
            paramsCamel.useCarpet,
            false,
            500,
            500
        );

        multiPositionManager.rebalance(paramsCamel, outMinCamel, inMinCamel);

        // Get positions and check distribution
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("\n=== CAMEL DOUBLE-HUMP ANALYSIS ===");
        console.log("Should show two peaks at center +/- range/5\n");

        // ASCII visualization of liquidity distribution
        _visualizeLiquidity(positions, positionData, basePositionsLength);

        // Find max liquidity for normalization
        uint256 maxLiquidity = 0;
        for (uint256 i = 0; i < basePositionsLength; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }

        // Expected peak positions
        int24 expectedLeftPeak = -200; // center - ticksLeft/5 = 0 - 1000/5
        int24 expectedRightPeak = 200; // center + ticksRight/5 = 0 + 1000/5

        console.log("\nExpected left peak around tick:", expectedLeftPeak);
        console.log("Expected right peak around tick:", expectedRightPeak);
        console.log("");

        // Visual distribution
        for (uint256 i = 0; i < basePositionsLength; i++) {
            int24 midTick = (positions[i].lowerTick + positions[i].upperTick) / 2;
            uint256 normalizedLiq = (positionData[i].liquidity * 100) / maxLiquidity;

            // Skip positions with very low liquidity for clarity
            if (normalizedLiq < 10) continue;

            console.log("Position", i);
            console.log("  Mid-tick:");
            console.logInt(midTick);
            console.log("  Liquidity:", positionData[i].liquidity);
            console.log("  Normalized:", normalizedLiq, "%");

            // Visual bar
            uint256 bars = normalizedLiq / 2; // Scale to 50 chars max
            string memory barChart = "  ";
            for (uint256 j = 0; j < bars; j++) {
                barChart = string(abi.encodePacked(barChart, "#"));
            }
            console.log(barChart);

            // Mark if near expected peaks
            if (_nearTick(midTick, expectedLeftPeak, 60)) {
                console.log("  << LEFT HUMP");
            } else if (_nearTick(midTick, expectedRightPeak, 60)) {
                console.log("  >> RIGHT HUMP");
            }
        }

        // Find actual peaks
        uint256 leftPeakLiquidity = 0;
        uint256 rightPeakLiquidity = 0;
        int24 leftPeakTick = 0;
        int24 rightPeakTick = 0;

        for (uint256 i = 0; i < basePositionsLength; i++) {
            int24 midTick = (positions[i].lowerTick + positions[i].upperTick) / 2;

            // Check left side
            if (midTick < 0 && positionData[i].liquidity > leftPeakLiquidity) {
                leftPeakLiquidity = positionData[i].liquidity;
                leftPeakTick = midTick;
            }

            // Check right side
            if (midTick > 0 && positionData[i].liquidity > rightPeakLiquidity) {
                rightPeakLiquidity = positionData[i].liquidity;
                rightPeakTick = midTick;
            }
        }

        console.log("\n=== PEAK ANALYSIS ===");
        console.log("Actual left peak at tick:");
        console.logInt(leftPeakTick);
        console.log("Actual right peak at tick:");
        console.logInt(rightPeakTick);

        // Verify we have two distinct peaks
        assertTrue(leftPeakLiquidity > 0, "Should have left peak");
        assertTrue(rightPeakLiquidity > 0, "Should have right peak");

        // Peaks should be near expected positions (within 2 ranges)
        assertTrue(_nearTick(leftPeakTick, expectedLeftPeak, 120), "Left peak near expected");
        assertTrue(_nearTick(rightPeakTick, expectedRightPeak, 120), "Right peak near expected");

        // Valley between peaks should have lower liquidity
        uint256 centerLiquidity = 0;
        for (uint256 i = 0; i < basePositionsLength; i++) {
            int24 midTick = (positions[i].lowerTick + positions[i].upperTick) / 2;
            if (_nearTick(midTick, 0, 30)) {
                centerLiquidity = positionData[i].liquidity;
                break;
            }
        }

        console.log("\nCenter liquidity should be lower than peaks");
        console.log("Center liquidity:", centerLiquidity);
        console.log("Left peak liquidity:", leftPeakLiquidity);
        console.log("Right peak liquidity:", rightPeakLiquidity);

        // Center should have lower liquidity than peaks (characteristic of camel)
        assertTrue(centerLiquidity < leftPeakLiquidity, "Valley lower than left peak");
        assertTrue(centerLiquidity < rightPeakLiquidity, "Valley lower than right peak");

        vm.stopPrank();
    }

    function _nearTick(int24 tick, int24 target, uint24 tolerance) private pure returns (bool) {
        int24 diff = tick > target ? tick - target : target - tick;
        return uint24(diff) <= tolerance;
    }

    function _visualizeLiquidity(
        IMultiPositionManager.Range[] memory positions,
        IMultiPositionManager.PositionData[] memory positionData,
        uint256 count
    ) internal pure {
        // Find max liquidity for scaling
        uint256 maxLiquidity = 0;
        for (uint256 i = 0; i < count; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }

        console.log("=== LIQUIDITY DISTRIBUTION VISUALIZATION ===");
        console.log("Legend: # = liquidity, L = left peak expected, R = right peak expected");
        console.log("--------------------------------------------------------------------------------");

        for (uint256 i = 0; i < count; i++) {
            int24 midTick = (positions[i].lowerTick + positions[i].upperTick) / 2;

            // Scale to 40 chars max
            uint256 barLength = maxLiquidity > 0 ? (uint256(positionData[i].liquidity) * 40) / maxLiquidity : 0;

            // Build the bar
            bytes memory bar = new bytes(40);
            for (uint256 j = 0; j < 40; j++) {
                bar[j] = j < barLength ? bytes1("#") : bytes1(" ");
            }

            // Mark expected peak zones
            string memory marker = "  ";
            if (midTick >= -260 && midTick <= -140) {
                marker = "L ";  // Left peak zone
            } else if (midTick >= 140 && midTick <= 260) {
                marker = "R ";  // Right peak zone
            } else if (midTick >= -60 && midTick <= 60) {
                marker = "V ";  // Valley (center)
            }

            // Calculate percentage
            uint256 pct = maxLiquidity > 0 ? (uint256(positionData[i].liquidity) * 100) / maxLiquidity : 0;

            console.log(
                string(abi.encodePacked(
                    "[", _int24ToString(positions[i].lowerTick), ",", _int24ToString(positions[i].upperTick), "]",
                    " ", marker, "|", string(bar), "| ", _uint256ToString(pct), "%"
                ))
            );
        }
        console.log("--------------------------------------------------------------------------------");
        console.log("L = Expected left peak zone (-260 to -140)");
        console.log("R = Expected right peak zone (140 to 260)");
        console.log("V = Expected valley/center zone (-60 to 60)");
    }

    function _int24ToString(int24 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        bool negative = value < 0;
        uint256 absValue = negative ? uint256(uint24(-value)) : uint256(uint24(value));

        bytes memory buffer = new bytes(10);
        uint256 i = buffer.length;

        while (absValue > 0) {
            i--;
            buffer[i] = bytes1(uint8(48 + absValue % 10));
            absValue /= 10;
        }

        if (negative) {
            i--;
            buffer[i] = bytes1("-");
        }

        bytes memory result = new bytes(buffer.length - i);
        for (uint256 j = 0; j < result.length; j++) {
            result[j] = buffer[i + j];
        }
        return string(result);
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        bytes memory buffer = new bytes(20);
        uint256 i = buffer.length;

        while (value > 0) {
            i--;
            buffer[i] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }

        bytes memory result = new bytes(buffer.length - i);
        for (uint256 j = 0; j < result.length; j++) {
            result[j] = buffer[i + j];
        }
        return string(result);
    }
}
