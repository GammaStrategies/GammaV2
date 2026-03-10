// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/MultiPositionManager/strategies/UniformStrategy.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";

contract TestExtremeTickValues is Test {
    UniformStrategy uniformStrategy;
    ExponentialStrategy exponentialStrategy;

    function setUp() public {
        uniformStrategy = new UniformStrategy();
        exponentialStrategy = new ExponentialStrategy();
    }

    function test_MaxInt24_GenerateRanges() public {
        console.log("Testing with max int24 value");

        int24 centerTick = type(int24).max; // 8388607
        uint24 ticksLeft = 900;
        uint24 ticksRight = 900;
        int24 tickSpacing = 60;
        bool useCarpet = false;

        console.log("centerTick:", centerTick);
        console.log("ticksLeft:", ticksLeft);
        console.log("ticksRight:", ticksRight);

        // Test UniformStrategy
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            uniformStrategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);

        console.log("UniformStrategy passed");
        console.log("Number of ranges:", lowerTicks.length);

        // Test ExponentialStrategy
        (lowerTicks, upperTicks) =
            exponentialStrategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);

        console.log("ExponentialStrategy passed");
        console.log("Number of ranges:", lowerTicks.length);
    }

    function test_MinInt24_GenerateRanges() public {
        console.log("Testing with min int24 value");

        int24 centerTick = type(int24).min; // -8388608
        uint24 ticksLeft = 900;
        uint24 ticksRight = 900;
        int24 tickSpacing = 60;
        bool useCarpet = false;

        console.log("centerTick:", centerTick);

        // Test UniformStrategy
        (int24[] memory lowerTicks, int24[] memory upperTicks) =
            uniformStrategy.generateRanges(centerTick, ticksLeft, ticksRight, tickSpacing, useCarpet);

        console.log("UniformStrategy passed");
        console.log("Number of ranges:", lowerTicks.length);
    }
}
