// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {RebalanceLogic} from "../src/MultiPositionManager/libraries/RebalanceLogic.sol";

contract RebalanceCenterClampTest is Test {
    function test_resolveAndClampCenterTick_SentinelBelowMinClampsToMinUsable() public pure {
        int24 tickSpacing = 60;
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 currentTick = minUsable - 1;

        int24 resolved = RebalanceLogic.resolveAndClampCenterTick(type(int24).max, currentTick, tickSpacing);

        assertEq(int256(resolved), int256(minUsable), "sentinel center should clamp to min usable tick");
    }

    function test_resolveAndClampCenterTick_ExplicitBelowMinClampsToMinUsable() public pure {
        int24 tickSpacing = 60;
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 explicitCenter = minUsable - tickSpacing;

        int24 resolved = RebalanceLogic.resolveAndClampCenterTick(explicitCenter, 0, tickSpacing);

        assertEq(int256(resolved), int256(minUsable), "explicit center below bounds should clamp to min usable tick");
    }

    function test_resolveAndClampCenterTick_ExplicitAboveMaxClampsToMaxUsable() public pure {
        int24 tickSpacing = 60;
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        int24 explicitCenter = maxUsable + tickSpacing;

        int24 resolved = RebalanceLogic.resolveAndClampCenterTick(explicitCenter, 0, tickSpacing);

        assertEq(int256(resolved), int256(maxUsable), "explicit center above bounds should clamp to max usable tick");
    }

    function test_resolveAndClampCenterTick_InRangeStillFloorSnaps() public pure {
        int24 tickSpacing = 60;

        int24 resolvedPositive = RebalanceLogic.resolveAndClampCenterTick(119, 0, tickSpacing);
        int24 resolvedNegative = RebalanceLogic.resolveAndClampCenterTick(-1, 0, tickSpacing);

        assertEq(int256(resolvedPositive), int256(60), "positive center should snap down to spacing");
        assertEq(int256(resolvedNegative), int256(-60), "negative center should floor-snap down to spacing");
    }
}
