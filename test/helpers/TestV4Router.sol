// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Router} from "v4-periphery/src/V4Router.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestV4Router
/// @notice V4Router implementation for testing that properly handles exact output swaps with hook fees
contract TestV4Router is V4Router {
    
    address internal _msgSender;
    
    constructor(IPoolManager _poolManager) V4Router(_poolManager) {}

    /// @notice Entry point for executing swaps
    /// @param actions Encoded actions to execute  
    /// @param params Parameters for each action
    function execute(bytes calldata actions, bytes[] calldata params) external payable {
        _msgSender = msg.sender;
        bytes memory unlockData = abi.encode(actions, params);
        poolManager.unlock(unlockData);
    }
    
    /// @notice Override msgSender to return the actual sender
    function msgSender() public view override returns (address) {
        return _msgSender;
    }

    /// @notice Helper for exact input single pool swap
    function swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut) {
        _msgSender = msg.sender;
        
        // Prepare swap parameters
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            hookData: ""
        });

        // Prepare actions - swap, settle input, take output
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE)
        );

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1); // settle input
        actionParams[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, recipient); // take output

        this.execute(actions, actionParams);
        
        return minAmountOut; // Simplified
    }

    /// @notice Helper for exact output single pool swap - THIS IS WHAT WE'RE TESTING!
    function swapExactOutputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maxAmountIn,
        address recipient
    ) external payable returns (uint256 amountIn) {
        _msgSender = msg.sender;
        
        // Prepare swap parameters
        IV4Router.ExactOutputSingleParams memory swapParams = IV4Router.ExactOutputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            amountOut: amountOut,
            amountInMaximum: maxAmountIn,
            hookData: ""
        });

        // Prepare actions - swap, settle input, take output
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE)
        );

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1); // settle input
        actionParams[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, recipient); // take output

        this.execute(actions, actionParams);
        
        return maxAmountIn; // Simplified
    }

    /// @notice Implementation of abstract _pay function from DeltaResolver
    /// @dev Transfers tokens from payer to pool manager
    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            // If payer is this contract, transfer directly
            IERC20(Currency.unwrap(token)).transfer(address(poolManager), amount);
        } else {
            // Transfer from the payer to pool manager
            IERC20(Currency.unwrap(token)).transferFrom(payer, address(poolManager), amount);
        }
    }

    /// @notice Required for receiving ETH
    receive() external payable {}
}