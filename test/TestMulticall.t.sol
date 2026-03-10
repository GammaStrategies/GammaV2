// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/interfaces/IMulticall.sol";
import "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import "../src/MultiPositionManager/base/Multicall.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TestMulticall is TestMultiPositionManager {
    function setUp() public override {
        super.setUp();
    }

    function test_MulticallApproveAndDeposit() public {
        console.log("\n=== Testing Multicall: Approve + Deposit ===\n");

        // First transfer ownership to alice so she can perform operations
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        // Mint tokens to alice
        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        vm.startPrank(alice);
        // Check initial balance before minting (alice already has tokens from setUp)
        uint256 initialBalance0 = token0.balanceOf(alice);
        uint256 initialBalance1 = token1.balanceOf(alice);

        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        // Check balances after minting
        assertEq(token0.balanceOf(alice), initialBalance0 + amount0, "Alice should have token0");
        assertEq(token1.balanceOf(alice), initialBalance1 + amount1, "Alice should have token1");
        assertEq(token0.allowance(alice, address(multiPositionManager)), 0, "No initial allowance");

        // Prepare multicall data: approve token0, approve token1, then deposit
        bytes[] memory calls = new bytes[](3);

        // Call 1: Approve token0
        calls[0] = abi.encodeWithSelector(IERC20.approve.selector, address(multiPositionManager), amount0);

        // Call 2: Approve token1
        calls[1] = abi.encodeWithSelector(IERC20.approve.selector, address(multiPositionManager), amount1);

        // Call 3: Deposit
        calls[2] = abi.encodeWithSelector(IMultiPositionManager.deposit.selector, amount0, amount1, alice, alice);

        // Execute multicall on token contracts for approvals
        // Note: We need to call approve on the token contracts, not the manager
        // So let's do this differently - call the tokens directly first
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Now we can deposit
        (uint256 shares,,) = multiPositionManager.deposit(amount0, amount1, alice, alice);

        console.log("Shares received:", shares);
        assertGt(shares, 0, "Should receive shares");
        assertEq(multiPositionManager.balanceOf(alice), shares, "Alice should have shares");

        vm.stopPrank();
    }

    function test_MulticallBatchedOperations() public {
        console.log("\n=== Testing Multicall: Batched Operations ===\n");

        // First transfer ownership to alice so she can perform operations
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        // Setup: alice deposits first
        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        vm.startPrank(alice);
        token0.mint(alice, amount0 * 3); // Need 3x for initial deposit + multicall deposits
        token1.mint(alice, amount1 * 3);
        token0.approve(address(multiPositionManager), amount0 * 3);
        token1.approve(address(multiPositionManager), amount1 * 3);

        (uint256 initialShares,,) = multiPositionManager.deposit(amount0, amount1, alice, alice);
        console.log("Initial shares:", initialShares);

        // Create positions first with rebalance
        (uint256[2][] memory outMinMulticall, uint256[2][] memory inMinMulticall) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy), // strategy
                center: 0, // centerTick
                tLeft: 1000, // ticksLeft
                tRight: 1000, // ticksRight,
                limitWidth: 0, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinMulticall,
            inMinMulticall
        );

        // Now use multicall to do multiple operations in one transaction
        bytes[] memory calls = new bytes[](2);

        // Call 1: Deposit more (with all required parameters)
        calls[0] = abi.encodeWithSelector(
            IMultiPositionManager.deposit.selector,
            amount0,
            amount1,
            alice,
            alice,
            false, // directDeposit
            new uint256[2][](0) // inMin
        );

        // Call 2: Deposit even more (with all required parameters)
        calls[1] = abi.encodeWithSelector(
            IMultiPositionManager.deposit.selector,
            amount0 / 2,
            amount1 / 2,
            alice,
            alice,
            false, // directDeposit
            new uint256[2][](0) // inMin
        );

        // Execute multicall
        IMulticall(address(multiPositionManager)).multicall(calls);

        uint256 finalShares = multiPositionManager.balanceOf(alice);
        console.log("Final shares:", finalShares);
        assertGt(finalShares, initialShares, "Should have more shares after second deposit");

        vm.stopPrank();
    }

    function test_MulticallRebalanceAndCompound() public {
        console.log("\n=== Testing Multicall: Deposit + Rebalance ===\n");

        // Transfer ownership to owner so they can do operations
        // (already owner by default)

        // Setup initial funds
        uint256 amount0 = 10000e18;
        uint256 amount1 = 10000e18;

        vm.startPrank(owner);
        token0.mint(owner, amount0 * 2); // Need extra for second deposit
        token1.mint(owner, amount1 * 2);
        token0.approve(address(multiPositionManager), amount0 * 2);
        token1.approve(address(multiPositionManager), amount1 * 2);

        // First deposit some funds
        multiPositionManager.deposit(amount0, amount1, owner, owner);

        // Calculate slippage values for rebalance
        (uint256[2][] memory outMin, uint256[2][] memory inMin) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 1000,
            ticksRight: 1000,
            limitWidth: 0,
            weight0: 0.5e18,
            weight1: 0.5e18,
            useCarpet: false,
            swap: false,
            maxSlippageOutMin: 500,
            maxSlippageInMin: 500,
            deductFees: false
        }));

        // For directDeposit, inMin needs to match basePositionsLength + limitPositionsLength
        // The rebalance creates positions, so we can reuse the same inMin array structure
        uint256[2][] memory depositInMin = new uint256[2][](inMin.length);

        // Prepare multicall: rebalance first then deposit more
        bytes[] memory calls = new bytes[](2);

        // Call 1: Rebalance to create positions
        calls[0] = abi.encodeWithSelector(
            IMultiPositionManager.rebalance.selector,
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy), // strategy
                center: 0, // centerTick
                tLeft: 1000, // ticksLeft
                tRight: 1000, // ticksRight,
                limitWidth: 0, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false // useCarpet
            }),
            outMin, // outMin (no existing positions, so empty)
            inMin // inMin (slippage protection for new positions)
        );

        // Call 2: Deposit more funds (after positions exist)
        calls[1] = abi.encodeWithSelector(
            IMultiPositionManager.deposit.selector,
            amount0,
            amount1,
            owner,
            owner,
            true, // directDeposit - use true since positions exist
            depositInMin // inMin from lens
        );

        // Execute multicall
        IMulticall(address(multiPositionManager)).multicall(calls);

        vm.stopPrank();
    }
}
