// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MulticallRouter
 * @notice Universal multicall router for batching any contract calls
 * @dev Allows batching token approvals, swaps, and MultiPositionManager operations in a single transaction
 */
contract MulticallRouter {
    using SafeERC20 for IERC20;

    error CallFailed(uint256 index, address target, bytes data, bytes reason);
    error InsufficientValue(uint256 required, uint256 provided);
    error DeadlineExpired();
    error UnauthorizedRecipient(address recipient);

    struct Call {
        address target; // Contract to call
        uint256 value; // ETH value to send
        bytes data; // Encoded function call
    }

    struct CallWithResult {
        address target;
        uint256 value;
        bytes data;
        bool requireSuccess; // If true, revert on failure
    }

    /**
     * @notice Execute multiple calls to different contracts
     * @param calls Array of calls to execute
     * @return results Array of return data from each call
     */
    function multicall(Call[] calldata calls) external payable returns (bytes[] memory results) {
        uint256 totalValue;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }
        if (msg.value < totalValue) {
            revert InsufficientValue(totalValue, msg.value);
        }

        results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call{value: calls[i].value}(calls[i].data);

            if (!success) {
                revert CallFailed(i, calls[i].target, calls[i].data, result);
            }

            results[i] = result;
        }

        // Return excess ETH
        if (address(this).balance > 0) {
            (bool sent,) = msg.sender.call{value: address(this).balance}("");
            require(sent, "Failed to return excess ETH");
        }
    }

    /**
     * @notice Execute multiple calls with optional failure handling
     * @param calls Array of calls with success requirements
     * @return results Array of return data from each call
     * @return successes Array indicating which calls succeeded
     */
    function multicallWithFailureHandling(CallWithResult[] calldata calls)
        external
        payable
        returns (bytes[] memory results, bool[] memory successes)
    {
        uint256 totalValue;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }
        if (msg.value < totalValue) {
            revert InsufficientValue(totalValue, msg.value);
        }

        results = new bytes[](calls.length);
        successes = new bool[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call{value: calls[i].value}(calls[i].data);

            if (!success && calls[i].requireSuccess) {
                revert CallFailed(i, calls[i].target, calls[i].data, result);
            }

            results[i] = result;
            successes[i] = success;
        }

        // Return excess ETH
        if (address(this).balance > 0) {
            (bool sent,) = msg.sender.call{value: address(this).balance}("");
            require(sent, "Failed to return excess ETH");
        }
    }

    /**
     * @notice Execute multiple calls with a deadline
     * @param deadline Timestamp after which the transaction reverts
     * @param calls Array of calls to execute
     * @return results Array of return data from each call
     */
    function multicallWithDeadline(uint256 deadline, Call[] calldata calls)
        external
        payable
        returns (bytes[] memory results)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        return this.multicall(calls);
    }

    /**
     * @notice Helper function for common pattern: Approve + Action
     * @param token Token to approve
     * @param spender Address to approve
     * @param amount Amount to approve
     * @param targetCall The actual action to perform after approval
     * @return approveResult Result from approve call
     * @return actionResult Result from action call
     */
    function approveAndCall(address token, address spender, uint256 amount, Call calldata targetCall)
        external
        payable
        returns (bytes memory approveResult, bytes memory actionResult)
    {
        // Approve
        (bool success1, bytes memory result1) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!success1) revert CallFailed(0, token, result1, result1);
        approveResult = result1;

        // Execute action
        (bool success2, bytes memory result2) = targetCall.target.call{value: targetCall.value}(targetCall.data);
        if (!success2) revert CallFailed(1, targetCall.target, targetCall.data, result2);
        actionResult = result2;

        // Return excess ETH
        if (address(this).balance > 0) {
            (bool sent,) = msg.sender.call{value: address(this).balance}("");
            require(sent, "Failed to return excess ETH");
        }
    }

    /**
     * @notice Rescue tokens sent to this contract by mistake
     * @param token Token to rescue (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external {
        // Only allow rescuing to msg.sender to prevent griefing
        if (to != msg.sender) revert UnauthorizedRecipient(to);

        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            require(sent, "Failed to send ETH");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // Receive ETH
    receive() external payable {}
}
