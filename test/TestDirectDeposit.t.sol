// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./MultiPositionManager.t.sol";
import "../src/MultiPositionManager/periphery/SimpleLens.sol";
import "../src/MultiPositionManager/libraries/DepositRatioLib.sol";
import "../src/MultiPositionManager/strategies/ExponentialStrategy.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import "forge-std/console.sol";

contract TestDirectDeposit is TestMultiPositionManager {
    SimpleLens directDepositLens;

    // Storage for deposit results to avoid stack too deep
    uint256 lastShares;
    uint256 lastDeposit0;
    uint256 lastDeposit1;

    // Struct to avoid stack too deep in test_DirectDeposit_DifferentRatio
    struct DepositTestData {
        uint256 totalBefore0;
        uint256 totalBefore1;
        uint256 totalAfter0;
        uint256 totalAfter1;
        uint256 deposit0Desired;
        uint256 deposit1Desired;
        uint256 expectedAmount0;
        uint256 expectedAmount1;
        uint256 basePositionsLength;
    }

    // Struct for comparison data to avoid stack too deep
    struct ComparisonData {
        uint256 totalPredicted0;
        uint256 totalPredicted1;
        uint256 totalActual0;
        uint256 totalActual1;
        uint256 actualAdded0;
        uint256 actualAdded1;
    }

    function setUp() public override {
        super.setUp();
        directDepositLens = new SimpleLens(manager);

        // The parent setUp already creates exponentialStrategy and sets up the registry
        // We just need to ensure it's available for our tests
        // Don't transfer ownership here - let individual tests do it if needed
    }

    function test_DirectDeposit_NoActivePositions() public {
        console.log("\n=== Test 1: Direct Deposit with No Active Positions ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        uint256 amount0 = 100e18;
        uint256 amount1 = 100e18;

        vm.startPrank(alice);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);
        token0.approve(address(multiPositionManager), amount0);
        token1.approve(address(multiPositionManager), amount1);

        // Get initial state
        (uint256 totalBefore0, uint256 totalBefore1,,) = multiPositionManager.getTotalAmounts();
        console.log(
            string.concat("Total before - token0: ", vm.toString(totalBefore0), " token1: ", vm.toString(totalBefore1))
        );

        // Direct deposit with no positions
        (uint256 shares, uint256 deposit0, uint256 deposit1) =
            multiPositionManager.deposit(amount0, amount1, alice, alice);

        console.log(string.concat("Shares received: ", vm.toString(shares)));
        console.log(string.concat("Amount0 deposited: ", vm.toString(deposit0)));
        console.log(string.concat("Amount1 deposited: ", vm.toString(deposit1)));

        // Verify all tokens go into vault without minting positions
        assertEq(deposit0, amount0, "Should deposit full amount0");
        assertEq(deposit1, amount1, "Should deposit full amount1");
        assertGt(shares, 0, "Should receive shares");

        // Check no positions were created
        (IMultiPositionManager.Range[] memory positions,) = multiPositionManager.getPositions();
        assertEq(positions.length, 0, "No positions should be created");

        // Verify tokens are just held in the vault
        (uint256 total0, uint256 total1,,) = multiPositionManager.getTotalAmounts();
        assertEq(total0, amount0, "All token0 should be in vault");
        assertEq(total1, amount1, "All token1 should be in vault");

        // Check actual token balances
        assertEq(token0.balanceOf(address(multiPositionManager)), amount0, "Contract should hold token0");
        assertEq(token1.balanceOf(address(multiPositionManager)), amount1, "Contract should hold token1");

        vm.stopPrank();
    }

    /*
    function test_DirectDeposit_WithBasePositions() public {
        console.log("\n=== Test 2: Direct Deposit with Lopsided Assets (2:1) and Base Positions ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);

        // Setup initial deposit
        _setupInitialDeposit(200e18, 100e18, 150e18, 75e18);

        // Alice already has ownership, no need to transfer again

        // Rebalance with exponential strategy, no limit positions
        (uint256[2][] memory outMinDD1, uint256[2][] memory inMinDD1) = SimpleLensInMin.getOutMinAndInMinForRebalance(multiPositionManager,
            address(exponentialStrategy),
            0,      // center
            1000,   // tLeft
            1000,   // tRight
            0,      // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            false,  // swap
            500     // 5% max slippage
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,  // centerTick
                tLeft: 1000,  // ticksLeft
                tRight: 1000,  // ticksRight,
                limitWidth: 0,  // limitWidth = 0 (no limit positions)
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD1,
            inMinDD1
        );

        vm.stopPrank();

        // Execute the test
        _executeDirectDepositTest(150e18, 75e18, 500); // 5% slippage
    }
    */

    function _setupInitialDeposit(uint256 initial0, uint256 initial1, uint256 extra0, uint256 extra1) internal {
        token0.mint(alice, initial0 + extra0);
        token1.mint(alice, initial1 + extra1);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);

        // First deposit
        multiPositionManager.deposit(initial0, initial1, alice, alice);

        console.log("Initial deposit - token0:", initial0, "token1:", initial1);
    }

    /*
    function _executeDirectDepositTest(
        uint256 deposit0Desired,
        uint256 deposit1Desired,
        uint256 slippage
    ) internal {
        // Log initial state
        _logInitialState();

        // Get and log expected amounts
        (uint256 totalBefore0, uint256 totalBefore1, , ) = multiPositionManager.getTotalAmounts();
        (uint256 expectedAmount0, uint256 expectedAmount1) = DepositRatioLib.getRatioAmounts(
            totalBefore0,
            totalBefore1,
            deposit0Desired,
            deposit1Desired
        );

        console.log("\nExpected amounts for positions:");
        console.log("  token0:", expectedAmount0);
        console.log("  token1:", expectedAmount1);

        // Perform the deposit and verify
        _performDirectDeposit(deposit0Desired, deposit1Desired, slippage);

        // Verify results
        _verifyDepositResults(deposit0Desired, deposit1Desired, totalBefore0, totalBefore1);
    }
    */

    function _logInitialState() internal view {
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("Base positions created:", basePositionsLength);
        console.log("Total positions:", positions.length);

        (uint256 totalBefore0, uint256 totalBefore1,,) = multiPositionManager.getTotalAmounts();
        console.log("\nBefore direct deposit:");
        console.log("  total0:", totalBefore0);
        console.log("  total1:", totalBefore1);

        // Log some position data
        console.log("\nPosition tokens BEFORE (first 3):");
        for (uint256 i = 0; i < 3 && i < positions.length; i++) {
            if (positionData[i].liquidity > 0) {
                console.log("Pos", i);
                console.log("  t0:", positionData[i].amount0);
                console.log("  t1:", positionData[i].amount1);
            }
        }
    }

    /*
    function _performDirectDeposit(
        uint256 deposit0Desired,
        uint256 deposit1Desired,
        uint256 slippage
    ) internal {
        // Get inMin
        uint256[2][] memory inMin = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            deposit0Desired,
            deposit1Desired,
            slippage
        );

        // Perform deposit and store results
        vm.startPrank(alice);
        (lastShares, lastDeposit0, lastDeposit1) = multiPositionManager.deposit(
            deposit0Desired,
            deposit1Desired,
            alice,
            alice
        );
        vm.stopPrank();

        console.log("\nDirect deposit results:");
        console.log("  Shares:", lastShares);
        console.log("  Deposit0:", lastDeposit0);
        console.log("  Deposit1:", lastDeposit1);
    }
    */

    function _verifyDepositResults(
        uint256 deposit0Desired,
        uint256 deposit1Desired,
        uint256 totalBefore0,
        uint256 totalBefore1
    ) internal {
        // Get final state
        (uint256 totalAfter0, uint256 totalAfter1,,) = multiPositionManager.getTotalAmounts();

        // Log position comparison
        _logPositionComparison(address(multiPositionManager), multiPositionManager.basePositionsLength());

        console.log("\nAfter direct deposit:");
        console.log("  total0:", totalAfter0);
        console.log("  total1:", totalAfter1);

        // Verify amounts using stored values
        assertEq(lastDeposit0, deposit0Desired, "Should deposit full amount0");
        assertEq(lastDeposit1, deposit1Desired, "Should deposit full amount1");

        // Verify totals
        assertApproxEqAbs(totalAfter0, totalBefore0 + lastDeposit0, 1e15, "Total0 correct");
        assertApproxEqAbs(totalAfter1, totalBefore1 + lastDeposit1, 1e15, "Total1 correct");

        // Verify ratio maintained
        if (totalBefore1 > 0 && totalAfter1 > 0) {
            uint256 ratioBefore = (totalBefore0 * 1e18) / totalBefore1;
            uint256 ratioAfter = (totalAfter0 * 1e18) / totalAfter1;
            console.log("\nRatio before:", ratioBefore / 1e16, "/ 100");
            console.log("Ratio after:", ratioAfter / 1e16, "/ 100");
            assertApproxEqRel(ratioAfter, ratioBefore, 0.01e18, "Ratio maintained");
        }
    }

    /*
    function test_DirectDeposit_WithLimitPositions() public {
        console.log("\n=== Test 3: Direct Deposit with Base and Limit Positions ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);

        // Initial lopsided deposit (2:1 ratio)
        uint256 initial0 = 200e18;
        uint256 initial1 = 100e18;

        token0.mint(alice, initial0 + 150e18);
        token1.mint(alice, initial1 + 75e18);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);

        // First deposit
        multiPositionManager.deposit(initial0,
            initial1,
            alice,
            alice);

        console.log(string.concat("Initial deposit - token0: ", vm.toString(initial0), " token1: ", vm.toString(initial1)));

        // Alice already has ownership, no need to transfer again

        // Rebalance with exponential strategy AND limit positions
        (uint256[2][] memory outMinDD2, uint256[2][] memory inMinDD2) = SimpleLensInMin.getOutMinAndInMinForRebalance(multiPositionManager,
            address(exponentialStrategy),
            0,      // center
            1000,   // tLeft
            1000,   // tRight
            60,     // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            false,  // swap
            500     // 5% max slippage
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,  // centerTick
                tLeft: 1000,  // ticksLeft
                tRight: 1000,  // ticksRight,
                limitWidth: 60,  // limitWidth = 60 (creates limit positions)
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD2,
            inMinDD2
        );

        // Get positions after rebalance
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) = multiPositionManager.getPositions();
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("\nPositions after rebalance:");
        console.log(string.concat("Base positions: ", vm.toString(basePositionsLength)));
        console.log(string.concat("Total positions: ", vm.toString(positions.length)));

        // Log all position details
        for (uint i = 0; i < positions.length; i++) {
            console.log(string.concat("Position ", vm.toString(i), " - liquidity: ", vm.toString(positionData[i].liquidity)));
            if (i < basePositionsLength) {
                console.log("  Type: Base position");
            } else {
                console.log("  Type: Limit position");
            }
            console.log(string.concat("  Range: ", vm.toString(positions[i].lowerTick), " to ", vm.toString(positions[i].upperTick)));
        }

        // Verify limit positions were created
        assertTrue(positions.length > basePositionsLength, "Limit positions should be created");

        // Get vault state before direct deposit
        (uint256 totalBefore0, uint256 totalBefore1, , ) = multiPositionManager.getTotalAmounts();
        console.log(string.concat("\nBefore direct deposit - total0: ", vm.toString(totalBefore0), " total1: ", vm.toString(totalBefore1)));

        // Calculate exact ratio
        uint256 deposit0Desired = 150e18;
        uint256 deposit1Desired = 75e18;

        (uint256 expectedAmount0, uint256 expectedAmount1) = DepositRatioLib.getRatioAmounts(
            totalBefore0,
            totalBefore1,
            deposit0Desired,
            deposit1Desired
        );

        console.log(string.concat("\nExpected for positions - token0: ", vm.toString(expectedAmount0), " token1: ", vm.toString(expectedAmount1)));

        // Use zero inMin for testing
        uint256[2][] memory inMin = new uint256[2][](basePositionsLength + 2);

        // Also calculate what inMin would be for comparison
        uint256[2][] memory calculatedInMin = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            deposit0Desired,
            deposit1Desired,
            100  // 1% slippage
        );

        console.log("\nCalculated InMin (not used) - includes limit positions:");
        for (uint i = 0; i < calculatedInMin.length; i++) {
            if (i < basePositionsLength) {
                console.log(string.concat("Base position ", vm.toString(i), " - token0: ", vm.toString(calculatedInMin[i][0]), " token1: ", vm.toString(calculatedInMin[i][1])));
            } else {
                console.log(string.concat("Limit position ", vm.toString(i - basePositionsLength), " - token0: ", vm.toString(calculatedInMin[i][0]), " token1: ", vm.toString(calculatedInMin[i][1])));
            }
        }

        // Track position liquidities before deposit
        uint128[] memory liquiditiesBefore = new uint128[](positions.length);
        for (uint i = 0; i < positions.length; i++) {
            liquiditiesBefore[i] = positionData[i].liquidity;
        }

        // Perform direct deposit
        (uint256 shares, uint256 actualDeposit0, uint256 actualDeposit1) = multiPositionManager.deposit(
            deposit0Desired,
            deposit1Desired,
            alice,
            alice
        );

        console.log("\nDirect deposit results:");
        console.log(string.concat("Shares: ", vm.toString(shares)));
        console.log(string.concat("Actual deposit0: ", vm.toString(actualDeposit0)));
        console.log(string.concat("Actual deposit1: ", vm.toString(actualDeposit1)));

        // Check that positions received liquidity (simplified to avoid stack issues)
        vm.stopPrank();
        _verifyLimitPositionChanges(address(multiPositionManager), liquiditiesBefore, basePositionsLength);

        // Get final state
        (uint256 totalAfter0, uint256 totalAfter1, , ) = multiPositionManager.getTotalAmounts();

        console.log(string.concat("\nFinal totals - token0: ", vm.toString(totalAfter0), " token1: ", vm.toString(totalAfter1)));

        // Verify totals and ratio
        {
            uint256 expectedTotal0 = totalBefore0 + actualDeposit0;
            uint256 expectedTotal1 = totalBefore1 + actualDeposit1;
            assertApproxEqAbs(totalAfter0, expectedTotal0, 1e15, "Total0 should increase correctly");
            assertApproxEqAbs(totalAfter1, expectedTotal1, 1e15, "Total1 should increase correctly");
        }

        if (totalBefore1 > 0 && totalAfter1 > 0) {
            uint256 ratioBefore = (totalBefore0 * 1e18) / totalBefore1;
            uint256 ratioAfter = (totalAfter0 * 1e18) / totalAfter1;
            assertApproxEqRel(ratioAfter, ratioBefore, 0.01e18, "Ratio maintained with limit positions");
        }
    }
    */

    /*
    function test_DirectDeposit_DifferentRatio() public {
        console.log("\n=== Test 4: Direct Deposit with Very Different Ratio ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);

        // Setup and initial deposit
        {
            token0.mint(alice, 600e18); // 100 for initial + 500 for second
            token1.mint(alice, 150e18); // 100 for initial + 50 for second
            token0.approve(address(multiPositionManager), type(uint256).max);
            token1.approve(address(multiPositionManager), type(uint256).max);

            // First deposit (balanced 1:1)
            multiPositionManager.deposit(100e18,
                100e18,
                alice,
                alice);

            console.log("Initial balanced deposit - token0: 100e18, token1: 100e18");
        }

        // Alice already has ownership, no need to transfer again

        // Rebalance with limit positions
        (uint256[2][] memory outMinDD3, uint256[2][] memory inMinDD3) = SimpleLensInMin.getOutMinAndInMinForRebalance(multiPositionManager,
            address(exponentialStrategy),
            0,      // center
            1000,   // tLeft
            1000,   // tRight
            60,     // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            false,  // swap
            500     // 5% max slippage
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 60,  // Create limit positions
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD3,
            inMinDD3
        );

        // Use struct to manage variables
        DepositTestData memory data;

        // Get state before direct deposit
        (data.totalBefore0, data.totalBefore1, , ) = multiPositionManager.getTotalAmounts();
        console.log(string.concat("\nVault before (1:1 ratio) - token0: ", vm.toString(data.totalBefore0), " token1: ", vm.toString(data.totalBefore1)));

        // Set deposit amounts
        data.deposit0Desired = 500e18;
        data.deposit1Desired = 50e18;

        console.log(string.concat("\nAttempting deposit with 10:1 ratio - token0: ", vm.toString(data.deposit0Desired), " token1: ", vm.toString(data.deposit1Desired)));

        // Calculate what can actually be used
        (data.expectedAmount0, data.expectedAmount1) = DepositRatioLib.getRatioAmounts(
            data.totalBefore0,
            data.totalBefore1,
            data.deposit0Desired,
            data.deposit1Desired
        );

        console.log(string.concat("Maximum that fits ratio - token0: ", vm.toString(data.expectedAmount0), " token1: ", vm.toString(data.expectedAmount1)));
        {
            uint256 idle0 = data.deposit0Desired - data.expectedAmount0;
            uint256 idle1 = data.deposit1Desired - data.expectedAmount1;
            console.log(string.concat("Will be left idle - token0: ", vm.toString(idle0), " token1: ", vm.toString(idle1)));
        }

        // Get inMin
        data.basePositionsLength = multiPositionManager.basePositionsLength();
        uint256[2][] memory inMin = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            data.deposit0Desired,
            data.deposit1Desired,
            100
        );

        // Track token balances
        uint256 contractToken0Before = token0.balanceOf(address(multiPositionManager));
        uint256 contractToken1Before = token1.balanceOf(address(multiPositionManager));

        // Perform direct deposit
        (uint256 shares, uint256 actualDeposit0, uint256 actualDeposit1) = multiPositionManager.deposit(data.deposit0Desired,
            data.deposit1Desired,
            alice,
            alice);

        console.log("\nDirect deposit results:");
        console.log(string.concat("Shares received: ", vm.toString(shares)));
        console.log(string.concat("Actually deposited - token0: ", vm.toString(actualDeposit0), " token1: ", vm.toString(actualDeposit1)));

        // Should accept full amounts even though not all goes to positions
        assertEq(actualDeposit0, data.deposit0Desired, "Should accept full token0");
        assertEq(actualDeposit1, data.deposit1Desired, "Should accept full token1");

        // Check contract balances - should hold the idle tokens
        uint256 contractToken0After = token0.balanceOf(address(multiPositionManager));
        uint256 contractToken1After = token1.balanceOf(address(multiPositionManager));

        // Contract should hold ALL deposited amounts as idle (deposit no longer adds to positions)
        // Allow for small rounding differences (up to 10 wei)
        assertApproxEqAbs(
            contractToken0After - contractToken0Before,
            data.deposit0Desired,
            10,
            "Contract should hold all deposited token0 as idle"
        );
        assertApproxEqAbs(
            contractToken1After - contractToken1Before,
            data.deposit1Desired,
            10,
            "Contract should hold all deposited token1 as idle"
        );

        // Get final totals
        (data.totalAfter0, data.totalAfter1, , ) = multiPositionManager.getTotalAmounts();

        console.log("\nFinal state:");
        console.log(string.concat("Total token0: ", vm.toString(data.totalAfter0), " Total token1: ", vm.toString(data.totalAfter1)));

        // Check positions got proportional increases
        {
            (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) = multiPositionManager.getPositions();

            console.log("\nPosition liquidity distribution:");
            for (uint i = 0; i < positions.length; i++) {
                if (i < data.basePositionsLength) {
                    console.log(string.concat("Base position ", vm.toString(i), " liquidity: ", vm.toString(positionData[i].liquidity)));
                } else {
                    uint256 limitIndex = i - data.basePositionsLength;
                    console.log(string.concat("Limit position ", vm.toString(limitIndex), " liquidity: ", vm.toString(positionData[i].liquidity)));
                }
            }
        }

        // Maximum amount should be used for positions, rest stays idle
        console.log("\nSummary:");
        console.log("Maximum tokens used for positions maintained the 1:1 ratio");
        console.log("Remaining tokens kept idle in vault");

        // Verify the ratio is closer to original after deposit
        // Using separate scope and minimal variables to avoid stack too deep
        vm.stopPrank();
        _verifyRatioChange(data.totalBefore0, data.totalBefore1, data.totalAfter0, data.totalAfter1);
    }
    */

    /*
    function test_InMinAccuracy() public {
        console.log("\n=== Test: InMin Prediction Accuracy ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);

        // Setup initial deposit
        _setupInitialDeposit(200e18, 100e18, 150e18, 75e18);

        // Alice already has ownership, no need to transfer again

        // Rebalance to create positions
        (uint256[2][] memory outMinDD4, uint256[2][] memory inMinDD4) = SimpleLensInMin.getOutMinAndInMinForRebalance(multiPositionManager,
            address(exponentialStrategy),
            0,      // center
            1000,   // tLeft
            1000,   // tRight
            0,      // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            false,  // swap
            500     // 5% max slippage
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 0,
                tLeft: 1000,
                tRight: 1000,
                limitWidth: 0,
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD4,
            inMinDD4
        );

        // Get positions before deposit
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionDataBefore) =
            multiPositionManager.getPositions();
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        // Amounts to deposit
        uint256 deposit0Desired = 150e18;
        uint256 deposit1Desired = 75e18;

        // Get inMin predictions with NO slippage (10000 = 100%, so 0% slippage)
        uint256[2][] memory inMinPredictions = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            deposit0Desired,
            deposit1Desired,
            0  // 0% slippage to get exact predictions
        );

        console.log("InMin predictions (what SimpleLens expects to add to each position):");
        for (uint i = 0; i < inMinPredictions.length; i++) {
            if (i < basePositionsLength && positionDataBefore[i].liquidity > 0) {
                console.log("Position", i);
                console.log("  Predicted token0 to add:", inMinPredictions[i][0]);
                console.log("  Predicted token1 to add:", inMinPredictions[i][1]);
            }
        }

        // Use predictions with some slippage tolerance for compound
        uint256[2][] memory inMinWithSlippage = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            deposit0Desired,
            deposit1Desired,
            100  // 1% slippage tolerance
        );

        // First deposit to vault (adds to idle balance)
        (uint256 shares, uint256 actualDeposit0, uint256 actualDeposit1) = multiPositionManager.deposit(
            deposit0Desired,
            deposit1Desired,
            alice,
            alice
        );

        console.log("\nDeposit complete. Shares:", shares);
        console.log("Deposited - token0:", actualDeposit0, "token1:", actualDeposit1);

        // Now compound to add idle balance to positions
        multiPositionManager.compound(inMinWithSlippage);

        // Get positions after deposit
        (, IMultiPositionManager.PositionData[] memory positionDataAfter) = multiPositionManager.getPositions();

        // Compare predictions with actual changes
        console.log("\n=== DETAILED COMPARISON: Predicted vs Actual ===");

        // Use struct to avoid stack too deep
        ComparisonData memory comp;

        for (uint i = 0; i < basePositionsLength; i++) {
            if (positionDataBefore[i].liquidity > 0) {
                comp.actualAdded0 = positionDataAfter[i].amount0 > positionDataBefore[i].amount0 ?
                    positionDataAfter[i].amount0 - positionDataBefore[i].amount0 : 0;
                comp.actualAdded1 = positionDataAfter[i].amount1 > positionDataBefore[i].amount1 ?
                    positionDataAfter[i].amount1 - positionDataBefore[i].amount1 : 0;

                console.log("\nPosition", i);
                console.log("  Predicted token0:", inMinPredictions[i][0], "Actual added:", comp.actualAdded0);
                if (inMinPredictions[i][0] > 0 || comp.actualAdded0 > 0) {
                    uint256 diff0 = comp.actualAdded0 > inMinPredictions[i][0] ?
                        comp.actualAdded0 - inMinPredictions[i][0] : inMinPredictions[i][0] - comp.actualAdded0;
                    if (diff0 > 0) {
                        console.log("    Difference:", diff0);
                    }
                }

                console.log("  Predicted token1:", inMinPredictions[i][1], "Actual added:", comp.actualAdded1);
                if (inMinPredictions[i][1] > 0 || comp.actualAdded1 > 0) {
                    uint256 diff1 = comp.actualAdded1 > inMinPredictions[i][1] ?
                        comp.actualAdded1 - inMinPredictions[i][1] : inMinPredictions[i][1] - comp.actualAdded1;
                    if (diff1 > 0) {
                        console.log("    Difference:", diff1);
                    }
                }

                comp.totalPredicted0 += inMinPredictions[i][0];
                comp.totalPredicted1 += inMinPredictions[i][1];
                comp.totalActual0 += comp.actualAdded0;
                comp.totalActual1 += comp.actualAdded1;
            }
        }

        console.log("\nTotals (all base positions):");
        console.log("  Total predicted token0:", comp.totalPredicted0);
        console.log("  Total actual token0:", comp.totalActual0);
        console.log("  Total predicted token1:", comp.totalPredicted1);
        console.log("  Total actual token1:", comp.totalActual1);

        if (comp.totalPredicted0 > 0) {
            uint256 percentDiff0 = ((comp.totalActual0 > comp.totalPredicted0 ? comp.totalActual0 - comp.totalPredicted0 : comp.totalPredicted0 - comp.totalActual0) * 10000) / comp.totalPredicted0;
            console.log("  Token0 difference:", percentDiff0, "basis points");
        }
        if (comp.totalPredicted1 > 0) {
            uint256 percentDiff1 = ((comp.totalActual1 > comp.totalPredicted1 ? comp.totalActual1 - comp.totalPredicted1 : comp.totalPredicted1 - comp.totalActual1) * 10000) / comp.totalPredicted1;
            console.log("  Token1 difference:", percentDiff1, "basis points");
        }

        // Verify predictions were reasonably accurate
        assertApproxEqAbs(comp.totalActual0, comp.totalPredicted0, 1e15, "Token0 predictions should be accurate");
        assertApproxEqAbs(comp.totalActual1, comp.totalPredicted1, 1e15, "Token1 predictions should be accurate");

        vm.stopPrank();
    }
    */

    /*
    function test_InMinAccuracy_BothTokens() public {
        // SKIP: After implementing width-based rounding (to match Python behavior),
        // position boundaries always land on multiples of width. Since 0 is a multiple
        // of any width, pool initialized at tick 0 will always have 0 as a position
        // boundary, never spanning it. This test requires a position with both tokens,
        // which only exists when a position spans the current price.
        // TODO: Modify test to use a different pool price or test setup
        vm.skip(true);

        console.log("\n=== Test: InMin Accuracy with Positions Containing Both Tokens ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);
        _setupInitialDeposit(200e18, 100e18, 150e18, 75e18);

        (uint256[2][] memory outMinDD6, uint256[2][] memory inMinDD6) = SimpleLensInMin.getOutMinAndInMinForRebalance(multiPositionManager,
            address(exponentialStrategy),
            30,
            1200,
            1200,
            0,      // limitWidth
            0.5e18, // weight0
            0.5e18, // weight1
            false,  // useCarpet
            false,  // swap
            500     // 5% max slippage
        );

        multiPositionManager.rebalance(
            IMultiPositionManager.RebalanceParams({
                strategy: address(exponentialStrategy),
                center: 30,    // center offset from 0
                tLeft: 1200,   // ticksLeft
                tRight: 1200,   // ticksRight,
                limitWidth: 0,      // no limit positions
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD6,
            inMinDD6
        );

        // Get positions and check which ones contain both tokens
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionDataBefore) =
            multiPositionManager.getPositions();
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();

        console.log("Positions created:", basePositionsLength);

        // Get actual current tick from pool
        (, int24 currentTick,,) = StateLibrary.getSlot0(multiPositionManager.poolManager(), key.toId());
        console.log("Current tick:", vm.toString(int256(currentTick)));
        console.log("\nPosition details (showing first 10):");

        for (uint i = 0; i < 10 && i < basePositionsLength; i++) {
            console.log("Position", i);
            console.logInt(positions[i].lowerTick);
            console.logInt(positions[i].upperTick);
            console.log("  Token0:", positionDataBefore[i].amount0);
            console.log("  Token1:", positionDataBefore[i].amount1);

            // Check if position spans current price
            if (positions[i].lowerTick <= currentTick && positions[i].upperTick > currentTick) {
                console.log("  ** This position spans current price and contains BOTH tokens **");
            }
        }

        // Find a position that has both tokens
        uint256 bothTokensPositionIndex = type(uint256).max;
        for (uint i = 0; i < basePositionsLength; i++) {
            if (positionDataBefore[i].amount0 > 0 && positionDataBefore[i].amount1 > 0) {
                bothTokensPositionIndex = i;
                console.log("\nFound position with both tokens:", i);
                console.log("Range:");
                console.logInt(positions[i].lowerTick);
                console.log("to");
                console.logInt(positions[i].upperTick);
                console.log("Token0:", positionDataBefore[i].amount0);
                console.log("Token1:", positionDataBefore[i].amount1);
                break;
            }
        }

        // Verify we found a position with both tokens
        require(bothTokensPositionIndex != type(uint256).max, "No position found with both tokens");
        uint256 centerPositionIndex = bothTokensPositionIndex;

        // Now test direct deposit with these positions
        uint256 deposit0Desired = 150e18;
        uint256 deposit1Desired = 75e18;

        // Check the ratio calculation
        (uint256 total0, uint256 total1, , ) = multiPositionManager.getTotalAmounts();
        console.log("\nVault totals before deposit:");
        console.log("  Token0:", total0);
        console.log("  Token1:", total1);

        // Calculate expected amounts for positions
        (uint256 expectedAmount0, uint256 expectedAmount1) = DepositRatioLib.getRatioAmounts(
            total0,
            total1,
            deposit0Desired,
            deposit1Desired
        );
        console.log("\nExpected amounts for positions:");
        console.log("  Token0:", expectedAmount0);
        console.log("  Token1:", expectedAmount1);

        // Get inMin predictions with some slippage to avoid PSC
        uint256[2][] memory inMinPredictions = directDepositLens.getInMinForDirectDeposit(
            address(multiPositionManager),
            deposit0Desired,
            deposit1Desired,
            500  // 5% slippage
        );

        // Show center position prediction
        console.log("\nCenter position", centerPositionIndex, "predictions:");
        console.log("  Predicted token0 to add:", inMinPredictions[centerPositionIndex][0]);
        console.log("  Predicted token1 to add:", inMinPredictions[centerPositionIndex][1]);

        // Store before amounts
        uint256 before0 = positionDataBefore[centerPositionIndex].amount0;
        uint256 before1 = positionDataBefore[centerPositionIndex].amount1;

        // Perform direct deposit
        (uint256 shares, , ) = multiPositionManager.deposit(
            deposit0Desired,
            deposit1Desired,
            alice,
            alice
        );

        console.log("\nDeposit complete. Shares:", shares);

        // Get positions after deposit and calculate changes
        uint256 actualAdded0;
        uint256 actualAdded1;
        {
            (, IMultiPositionManager.PositionData[] memory posDataAfter) = multiPositionManager.getPositions();
            actualAdded0 = posDataAfter[centerPositionIndex].amount0 - before0;
            actualAdded1 = posDataAfter[centerPositionIndex].amount1 - before1;
        }

        // Store predictions in local vars to avoid repeated access
        uint256 minToken0 = inMinPredictions[centerPositionIndex][0];
        uint256 minToken1 = inMinPredictions[centerPositionIndex][1];

        console.log("\n=== Center Position Comparison ===");
        console.log("Token0 - Predicted:", minToken0, "Actual:", actualAdded0);
        console.log("Token1 - Predicted:", minToken1, "Actual:", actualAdded1);

        // Verify actual is at least the minimum (with 5% slippage tolerance)
        assertGe(actualAdded0, minToken0, "Token0 should be at least inMin");
        assertGe(actualAdded1, minToken1, "Token1 should be at least inMin");

        // Additional verification that both tokens were added to the center position
        console.log("\n=== Verification ===");
        assertTrue(actualAdded0 > 0, "Should have added token0 to center position");
        assertTrue(actualAdded1 > 0, "Should have added token1 to center position");
        console.log("SUCCESS: Position with both tokens correctly predicted and updated!");

        vm.stopPrank();
    }
    */

    function _compareNearbyPositions(
        uint256 centerIndex,
        IMultiPositionManager.PositionData[] memory posBefore,
        IMultiPositionManager.PositionData[] memory posAfter,
        uint256[2][] memory predictions,
        uint256 baseLength
    ) internal {
        uint256 startIdx = centerIndex > 2 ? centerIndex - 2 : 0;
        uint256 endIdx = centerIndex + 2 < baseLength ? centerIndex + 2 : baseLength - 1;

        for (uint256 i = startIdx; i <= endIdx; i++) {
            if (posBefore[i].liquidity > 0) {
                uint256 added0 =
                    posAfter[i].amount0 > posBefore[i].amount0 ? posAfter[i].amount0 - posBefore[i].amount0 : 0;
                uint256 added1 =
                    posAfter[i].amount1 > posBefore[i].amount1 ? posAfter[i].amount1 - posBefore[i].amount1 : 0;

                console.log("Position", i);
                console.log("  Token0 - Predicted:", predictions[i][0], "Actual:", added0);
                console.log("  Token1 - Predicted:", predictions[i][1], "Actual:", added1);

                assertEq(added0, predictions[i][0], "Token0 should match");
                assertEq(added1, predictions[i][1], "Token1 should match");
            }
        }
    }

    function _verifyRatioChange(uint256 totalBefore0, uint256 totalBefore1, uint256 totalAfter0, uint256 totalAfter1)
        internal
    {
        uint256 ratioBefore = (totalBefore0 * 1e18) / totalBefore1;
        uint256 ratioAfter = (totalAfter0 * 1e18) / totalAfter1;

        console.log(string.concat("Ratio before: ", vm.toString(ratioBefore / 1e16), " / 100"));
        console.log(string.concat("Ratio after: ", vm.toString(ratioAfter / 1e16), " / 100"));

        // The ratio should have moved but not as much as if we had used all tokens
        assertTrue(ratioAfter > ratioBefore, "Ratio should increase due to more token0");
        assertTrue(ratioAfter < (10 * 1e18), "Ratio should be less than 10:1");
    }

    function _logPositionComparison(address mpmAddress, uint256 basePositionsLength) internal view {
        MultiPositionManager mpm = MultiPositionManager(payable(mpmAddress));
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory posData) =
            mpm.getPositions();

        console.log("\nPosition token amounts AFTER deposit (first 5):");
        uint256 totalToken0 = 0;
        uint256 totalToken1 = 0;

        for (uint256 i = 0; i < positions.length && i < 5; i++) {
            if (posData[i].liquidity > 0) {
                console.log("Pos", i);
                console.log("  token0:", posData[i].amount0);
                console.log("  token1:", posData[i].amount1);
                totalToken0 += posData[i].amount0;
                totalToken1 += posData[i].amount1;
            }
        }

        // Log totals for all positions
        for (uint256 i = 5; i < positions.length; i++) {
            totalToken0 += posData[i].amount0;
            totalToken1 += posData[i].amount1;
        }

        console.log("Total in all positions after:");
        console.log("  token0:", totalToken0);
        console.log("  token1:", totalToken1);
    }

    // ============ Visual Distribution Test ============

    function test_DirectDeposit_80_20_Visual_Distribution() public {
        console.log("\n=== Test: 80/20 Initial, Rebalance to 50/50, Then 80/20 Direct Deposit ===\n");

        // Transfer ownership to alice first (she needs to be owner to deposit)
        vm.prank(owner);
        multiPositionManager.transferOwnership(alice);

        vm.startPrank(alice);

        // Step 1: Initial 80/20 deposit
        console.log("STEP 1: Initial 80/20 Deposit");
        console.log("================================");
        uint256 initial0 = 80e18;
        uint256 initial1 = 20e18;

        token0.mint(alice, initial0 * 3); // Extra for second deposit
        token1.mint(alice, initial1 * 3);
        token0.approve(address(multiPositionManager), type(uint256).max);
        token1.approve(address(multiPositionManager), type(uint256).max);

        multiPositionManager.deposit(initial0, initial1, alice, alice);

        console.log("Deposited: 80 token0, 20 token1");
        console.log("");

        // Step 2: Rebalance to 50/50 exponential
        console.log("STEP 2: Rebalance to 50/50 Exponential");
        console.log("========================================");

        // Rebalance using exponential strategy
        // The strategy will create a balanced distribution
        (uint256[2][] memory outMinDD5, uint256[2][] memory inMinDD5) =         SimpleLensInMin.getOutMinAndInMinForRebalance(SimpleLensInMin.RebalanceMinParams({
            manager: multiPositionManager,
            strategyAddress: address(exponentialStrategy),
            centerTick: 0,
            ticksLeft: 600,
            ticksRight: 600,
            limitWidth: 60,
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
                strategy: address(exponentialStrategy),
                center: 0, // centerTick
                tLeft: 600, // ticksLeft
                tRight: 600, // ticksRight,
                limitWidth: 60, // limitWidth
                weight0: 0.5e18,
                weight1: 0.5e18,
                useCarpet: false
            }),
            outMinDD5,
            inMinDD5
        );

        console.log("Rebalanced with exponential strategy (creates balanced distribution)");
        _visualizePositions("After Rebalance to 50/50");

        // Get state before second deposit
        (uint256 before0, uint256 before1,,) = multiPositionManager.getTotalAmounts();
        console.log("Total before second deposit:");
        console.log("  Token0:", _formatAmount(before0));
        console.log("  Token1:", _formatAmount(before1));
        console.log("");

        // Step 3: Second 80/20 deposit with 2x amounts using direct deposit
        console.log("STEP 3: Second 80/20 Direct Deposit (2x Initial)");
        console.log("=================================================");
        uint256 second0 = 160e18; // 2x initial
        uint256 second1 = 40e18; // 2x initial

        console.log("Depositing: 160 token0, 40 token1 (direct deposit)");

        // Calculate inMin for direct deposit
        uint256 basePositionsLength = multiPositionManager.basePositionsLength();
        uint256 limitPositionsLength = multiPositionManager.limitPositionsLength();
        uint256 totalPositions = basePositionsLength + limitPositionsLength;

        uint256[2][] memory inMin = new uint256[2][](totalPositions);
        // Set minimal slippage protection (1% for this test)
        for (uint256 i = 0; i < totalPositions; i++) {
            inMin[i][0] = 0; // No minimum for simplicity in test
            inMin[i][1] = 0;
        }

        (uint256 shares, uint256 actualDeposit0, uint256 actualDeposit1) =
            multiPositionManager.deposit(second0, second1, alice, alice);

        console.log("Direct deposit complete:");
        console.log("  Shares received:", shares);
        console.log("  Actual token0 deposited:", _formatAmount(actualDeposit0));
        console.log("  Actual token1 deposited:", _formatAmount(actualDeposit1));
        console.log("");

        // Visualize final state
        _visualizePositions("After Direct Deposit");

        // Get final state
        (uint256 after0, uint256 after1,,) = multiPositionManager.getTotalAmounts();
        console.log("Final totals:");
        console.log("  Token0:", _formatAmount(after0));
        console.log("  Token1:", _formatAmount(after1));
        console.log("");

        // Show the change
        console.log("Change from direct deposit:");
        console.log("  Token0 added to positions:", _formatAmount(after0 - before0));
        console.log("  Token1 added to positions:", _formatAmount(after1 - before1));

        // Calculate and show ratios
        uint256 ratioBefore = (before0 * 100) / before1;
        uint256 ratioAfter = (after0 * 100) / after1;
        console.log("");
        console.log("Token0/Token1 Ratio:");
        console.log("  Before direct deposit:", ratioBefore, "/ 100");
        console.log("  After direct deposit:", ratioAfter, "/ 100");
        console.log("  Ratio maintained:", _closeEnough(ratioBefore, ratioAfter, 200) ? "YES (within 2%)" : "NO");

        vm.stopPrank();
    }

    // ============ Visualization Helper Functions ============

    function _visualizePositions(string memory title) internal view override {
        (IMultiPositionManager.Range[] memory positions, IMultiPositionManager.PositionData[] memory positionData) =
            multiPositionManager.getPositions();

        // Get current tick
        int24 currentTick = multiPositionManager.currentTick();

        // Separate base positions and limit positions
        uint256 baseCount = multiPositionManager.basePositionsLength();
        uint256 limitCount = multiPositionManager.limitPositionsLength();

        console.log("");
        console.log(title);
        console.log(_repeatChar("=", 60));
        console.log("Current Tick:", _tickToString(currentTick));
        console.log("Base Positions:", baseCount);
        console.log("Limit Positions:", limitCount);
        console.log("");

        // Find max liquidity for scaling
        uint128 maxLiquidity = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positionData[i].liquidity > maxLiquidity) {
                maxLiquidity = positionData[i].liquidity;
            }
        }

        // Create the graph
        console.log("Liquidity Distribution:");
        console.log("Legend: # = Token0, = = Both tokens, - = Token1");
        console.log("");

        // Show positions with their tick ranges and liquidity bars
        for (uint256 i = 0; i < positions.length; i++) {
            if (positionData[i].liquidity > 0) {
                _displayPosition(positions[i], positionData[i], maxLiquidity, i < baseCount);
            }
        }

        console.log("");
    }

    function _displayPosition(
        IMultiPositionManager.Range memory position,
        IMultiPositionManager.PositionData memory data,
        uint128 maxLiquidity,
        bool isBase
    ) internal view {
        uint256 percentage = (uint256(data.liquidity) * 100) / uint256(maxLiquidity);

        // Determine which token the position holds
        bool hasToken0 = data.amount0 > 0;
        bool hasToken1 = data.amount1 > 0;
        string memory barChar;
        if (hasToken0 && hasToken1) {
            barChar = "="; // Both tokens
        } else if (hasToken0) {
            barChar = "#"; // Token0 only
        } else {
            barChar = "-"; // Token1 only
        }

        string memory bar = _createBarWithChar(percentage, barChar);
        string memory posType = isBase ? "Base" : "Limit";

        // Display tick range and bar
        console.log(
            string(
                abi.encodePacked(
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

        // Show token amounts
        console.log(
            string(
                abi.encodePacked(
                    "  Token0: ",
                    _formatAmount(data.amount0),
                    " | Token1: ",
                    _formatAmount(data.amount1),
                    " | Liq: ",
                    _formatLiquidity(data.liquidity)
                )
            )
        );
    }

    function _createBarWithChar(uint256 percentage, string memory char)
        internal
        pure
        override
        returns (string memory)
    {
        uint256 barLength = (percentage * 30) / 100; // Scale to 30 chars max
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

        // Convert to ether units (divide by 1e18)
        uint256 etherAmount = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e16; // Get 2 decimal places

        return
            string(abi.encodePacked(_uintToString(etherAmount), ".", decimal < 10 ? "0" : "", _uintToString(decimal)));
    }

    function _formatLiquidity(uint128 liquidity) internal pure returns (string memory) {
        if (liquidity == 0) return "0";

        // Format liquidity in a readable way (divide by 1e18 for display)
        uint256 scaled = uint256(liquidity) / 1e15; // Show in thousands
        return string(abi.encodePacked(_uintToString(scaled), "k"));
    }

    function _closeEnough(uint256 a, uint256 b, uint256 toleranceBps) internal pure returns (bool) {
        if (a == b) return true;
        uint256 diff = a > b ? a - b : b - a;
        uint256 max = a > b ? a : b;
        return (diff * 10000) / max <= toleranceBps;
    }

    function _verifyLimitPositionChanges(
        address mpmAddress,
        uint128[] memory liquiditiesBefore,
        uint256 basePositionsLength
    ) internal view {
        MultiPositionManager mpm = MultiPositionManager(payable(mpmAddress));
        (, IMultiPositionManager.PositionData[] memory posDataAfter) = mpm.getPositions();

        console.log("\nLiquidity changes (simplified):");
        // Check first few base positions
        for (uint256 i = 0; i < 3 && i < basePositionsLength; i++) {
            if (liquiditiesBefore[i] > 0) {
                uint128 increase = posDataAfter[i].liquidity - liquiditiesBefore[i];
                console.log(string.concat("Base pos ", vm.toString(i), " increase: ", vm.toString(increase)));
            }
        }

        // Check limit positions if they exist
        if (posDataAfter.length > basePositionsLength && liquiditiesBefore[basePositionsLength] > 0) {
            uint128 limitIncrease = posDataAfter[basePositionsLength].liquidity - liquiditiesBefore[basePositionsLength];
            console.log(string.concat("First limit pos increase: ", vm.toString(limitIncrease)));
            assertTrue(limitIncrease > 0, "Limit position should receive liquidity");
        }
    }
}
