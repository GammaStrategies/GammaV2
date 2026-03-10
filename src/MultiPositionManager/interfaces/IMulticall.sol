// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title IMulticall
 * @notice Interface for batching multiple calls in a single transaction
 */
interface IMulticall {
    /**
     * @notice Execute multiple calls in a single transaction
     * @param data Array of encoded function calls
     * @return results Array of return data from each call
     */
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
