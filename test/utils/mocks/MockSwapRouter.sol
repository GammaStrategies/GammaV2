// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockSwapRouter
 * @notice Mock DEX aggregator for testing swap functionality
 * @dev Simulates both Augustus v6.2 and Odos behavior
 */
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    error InvalidReceiver();
    error InsufficientInput();
    error SwapFailed();

    uint256 public constant SWAP_RATE_MULTIPLIER = 95; // 95% rate (5% slippage simulation)
    uint256 public constant SWAP_RATE_DIVISOR = 100;

    // For testing: track last swap details
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;
    address public lastReceiver;

    // Custom swap rate for specific testing scenarios
    uint256 public customSwapRate = SWAP_RATE_MULTIPLIER;

    event SwapExecuted(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed receiver
    );

    /**
     * @notice Set a custom swap rate for testing
     * @param rate The numerator for swap rate (denominator is 100)
     */
    function setSwapRate(uint256 rate) external {
        customSwapRate = rate;
    }

    /**
     * @notice Execute a swap (Augustus v6.2 style - direct approval)
     * @param callData Encoded swap parameters
     * @dev Expects calldata format: (tokenIn, tokenOut, amountIn, receiver)
     */
    function swap(bytes calldata callData) external payable {
        // Decode parameters
        (address tokenIn, address tokenOut, uint256 amountIn, address receiver) =
            abi.decode(callData, (address, address, uint256, address));

        _executeSwap(tokenIn, tokenOut, amountIn, receiver);
    }

    /**
     * @notice Execute a swap with explicit parameters (for simpler testing)
     */
    function swapExplicit(address tokenIn, address tokenOut, uint256 amountIn, address receiver) external payable {
        _executeSwap(tokenIn, tokenOut, amountIn, receiver);
    }

    /**
     * @notice Fallback function to handle any aggregator-style call
     * @dev Tries to decode common aggregator patterns
     */
    fallback() external payable {
        // Try to extract receiver from common positions in calldata
        if (msg.data.length >= 0xC4 + 32) {
            address receiver;
            assembly {
                receiver := calldataload(0xC4)
            }

            // For testing: perform a simple swap
            // In a real scenario, we'd decode the full swap parameters
            _performSimpleSwap(receiver);
        } else {
            revert SwapFailed();
        }
    }

    receive() external payable {}

    /**
     * @notice Internal swap execution logic
     */
    function _executeSwap(address tokenIn, address tokenOut, uint256 amountIn, address receiver) internal {
        if (receiver == address(0)) revert InvalidReceiver();
        if (amountIn == 0) revert InsufficientInput();

        // Store swap details for verification
        lastTokenIn = tokenIn;
        lastTokenOut = tokenOut;
        lastAmountIn = amountIn;
        lastReceiver = receiver;

        uint256 amountOut;

        // Handle ETH swaps
        if (tokenIn == address(0)) {
            // ETH -> Token swap
            if (msg.value != amountIn) revert InsufficientInput();

            // Calculate output amount (simulated rate)
            amountOut = (amountIn * customSwapRate) / SWAP_RATE_DIVISOR;

            // Transfer output tokens to receiver
            IERC20(tokenOut).safeTransfer(receiver, amountOut);
        } else if (tokenOut == address(0)) {
            // Token -> ETH swap
            // Pull input tokens
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

            // Calculate output amount
            amountOut = (amountIn * customSwapRate) / SWAP_RATE_DIVISOR;

            // Send ETH to receiver
            (bool success,) = receiver.call{value: amountOut}("");
            if (!success) revert SwapFailed();
        } else {
            // Token -> Token swap
            // Pull input tokens
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

            // Calculate output amount
            amountOut = (amountIn * customSwapRate) / SWAP_RATE_DIVISOR;

            // Transfer output tokens
            IERC20(tokenOut).safeTransfer(receiver, amountOut);
        }

        lastAmountOut = amountOut;
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, receiver);
    }

    /**
     * @notice Simple swap for fallback testing
     */
    function _performSimpleSwap(address receiver) internal {
        // For testing: just send back 95% of ETH received
        if (msg.value > 0) {
            uint256 amountOut = (msg.value * customSwapRate) / SWAP_RATE_DIVISOR;
            (bool success,) = receiver.call{value: amountOut}("");
            if (!success) revert SwapFailed();

            lastReceiver = receiver;
            lastAmountIn = msg.value;
            lastAmountOut = amountOut;
        }
    }

    /**
     * @notice Fund the mock with tokens for testing
     */
    function fundWithTokens(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Fund the mock with ETH
     */
    function fundWithETH() external payable {}
}
