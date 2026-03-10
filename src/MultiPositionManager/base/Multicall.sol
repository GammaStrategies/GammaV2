// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "../interfaces/IMulticall.sol";

/**
 * @title Multicall
 * @notice Enables calling multiple methods in a single transaction
 * @dev Provides a function to batch together multiple calls in a single external call
 *      Uses transient storage to track multicall context and prevent native ETH double-spend
 */
abstract contract Multicall is IMulticall {
    error MulticallFailed(uint256 index, bytes reason);

    /// @dev Transient storage slot for multicall context flag: keccak256("multicall.context")
    bytes32 private constant _MULTICALL_CONTEXT_SLOT =
        0x2e40f768ac3179109b141c8c4ebd71d79ff175997abe8aa5bd1bbfe613dc9f1f;

    /// @dev Transient storage slot for tracking if native deposit already done: keccak256("multicall.nativeDepositDone")
    bytes32 private constant _NATIVE_DEPOSIT_DONE_SLOT =
        0x11ac6ef1c72502e61aa6ad82b1888cc53ee565c9bcc98d36d57afcf87daa78d4;

    /**
     * @notice Execute multiple calls in a single transaction
     * @param data Array of encoded function calls
     * @return results Array of return data from each call
     */
    function multicall(bytes[] calldata data) public payable virtual override returns (bytes[] memory results) {
        // Set multicall context flag
        assembly {
            tstore(_MULTICALL_CONTEXT_SLOT, 1)
        }

        results = new bytes[](data.length);

        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // Clear flags before reverting
                assembly {
                    tstore(_MULTICALL_CONTEXT_SLOT, 0)
                    tstore(_NATIVE_DEPOSIT_DONE_SLOT, 0)
                }
                // Decode revert reason if possible
                if (result.length > 0) {
                    // Bubble up the revert reason
                    assembly {
                        revert(add(32, result), mload(result))
                    }
                } else {
                    revert MulticallFailed(i, result);
                }
            }

            results[i] = result;
        }

        // Clear flags at end of multicall
        assembly {
            tstore(_MULTICALL_CONTEXT_SLOT, 0)
            tstore(_NATIVE_DEPOSIT_DONE_SLOT, 0)
        }
    }

    /// @notice Check if currently executing within a multicall
    /// @return inContext True if in multicall context
    function _inMulticallContext() internal view returns (bool inContext) {
        assembly {
            inContext := tload(_MULTICALL_CONTEXT_SLOT)
        }
    }

    /// @notice Mark that a native ETH deposit has been done in this multicall
    function _markNativeDepositDone() internal {
        assembly {
            tstore(_NATIVE_DEPOSIT_DONE_SLOT, 1)
        }
    }

    /// @notice Check if a native ETH deposit has already been done in this multicall
    /// @return done True if native deposit already done
    function _isNativeDepositDone() internal view returns (bool done) {
        assembly {
            done := tload(_NATIVE_DEPOSIT_DONE_SLOT)
        }
    }
}
