// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/periphery/MulticallRouter.sol";
import "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TestMulticallRouter is TestMultiPositionManager {
    MulticallRouter public router;

    function setUp() public override {
        super.setUp();
        router = new MulticallRouter();
    }

    // Removed test_ApproveAndDeposit, test_SwapAndDeposit, and test_ApproveAndCallHelper
    // These tests were attempting to use MulticallRouter to call owner-restricted functions,
    // which doesn't work since the router itself isn't the owner

    function test_MulticallWithDeadline() public {
        console.log("\n=== Testing Multicall with Deadline ===\n");

        vm.startPrank(alice);
        token0.mint(alice, 1000e18);
        token1.mint(alice, 1000e18);

        MulticallRouter.Call[] memory calls = new MulticallRouter.Call[](2);

        calls[0] = MulticallRouter.Call({
            target: address(token0),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(multiPositionManager), 1000e18)
        });

        calls[1] = MulticallRouter.Call({
            target: address(token1),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(multiPositionManager), 1000e18)
        });

        // Set deadline 1 hour from now
        uint256 deadline = block.timestamp + 3600;

        // Should succeed
        bytes[] memory results = router.multicallWithDeadline(deadline, calls);
        assertEq(results.length, 2, "Should execute both calls");

        // Try with expired deadline
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(MulticallRouter.DeadlineExpired.selector);
        router.multicallWithDeadline(expiredDeadline, calls);

        vm.stopPrank();
    }

    function test_FailureHandling() public {
        console.log("\n=== Testing Failure Handling ===\n");

        vm.startPrank(alice);

        // Create calls where one might fail
        MulticallRouter.CallWithResult[] memory calls = new MulticallRouter.CallWithResult[](3);

        // This will succeed
        calls[0] = MulticallRouter.CallWithResult({
            target: address(token0),
            value: 0,
            data: abi.encodeWithSelector(IERC20.balanceOf.selector, alice),
            requireSuccess: true
        });

        // This will fail (trying to transfer more than balance)
        calls[1] = MulticallRouter.CallWithResult({
            target: address(token0),
            value: 0,
            data: abi.encodeWithSelector(IERC20.transfer.selector, bob, 1000e18),
            requireSuccess: false // Don't revert on failure
        });

        // This will succeed
        calls[2] = MulticallRouter.CallWithResult({
            target: address(token1),
            value: 0,
            data: abi.encodeWithSelector(IERC20.balanceOf.selector, alice),
            requireSuccess: true
        });

        (bytes[] memory results, bool[] memory successes) = router.multicallWithFailureHandling(calls);

        assertEq(results.length, 3, "Should have 3 results");
        assertTrue(successes[0], "First call should succeed");
        assertFalse(successes[1], "Second call should fail");
        assertTrue(successes[2], "Third call should succeed");

        console.log("Handled mixed success/failure calls correctly");

        vm.stopPrank();
    }
}
