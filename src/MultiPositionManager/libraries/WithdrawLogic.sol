// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMultiPositionManager} from "../interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "../interfaces/IMultiPositionFactory.sol";
import {ILiquidityStrategy} from "../strategies/ILiquidityStrategy.sol";
import {SharedStructs} from "../base/SharedStructs.sol";
import {PoolManagerUtils} from "./PoolManagerUtils.sol";
import {RebalanceLogic} from "./RebalanceLogic.sol";
import {PositionLogic} from "./PositionLogic.sol";

/**
 * @title WithdrawLogic
 * @notice Library containing all withdrawal-related logic for MultiPositionManager
 */
library WithdrawLogic {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 constant PRECISION = 1e36;

    // Struct to reduce stack depth
    struct CustomWithdrawParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        address to;
        uint256[2][] outMin;
        uint256 totalSupply;
        uint256 senderBalance;
        address sender;
    }

    // Custom errors
    error ZeroValue();
    error ZeroAddress();
    error InvalidRecipient();
    error AmountMustBePositive();
    error InsufficientBalance();
    error NoSharesExist();
    error OutMinLengthMismatch();

    // Events (will be emitted by main contract)
    event Withdraw(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 shares, uint256 totalSupply, uint256 amount0, uint256 amount1);
    event WithdrawCustom(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);

    // Withdrawal path enum
    enum WithdrawPath {
        USE_CURRENT_BALANCE, // Step 1: sufficient idle balance
        USE_BALANCE_PLUS_FEES, // Step 2: need zeroBurn for fees
        BURN_AND_WITHDRAW // Step 3: burn positions to satisfy withdrawal (no rebalance)

    }

    // Withdrawal path info struct
    struct WithdrawPathInfo {
        WithdrawPath path;
        uint256 currentBalance0;
        uint256 currentBalance1;
        uint256 total0;
        uint256 total1;
        uint256 totalFee0;
        uint256 totalFee1;
    }

    /**
     * @notice Determine which withdrawal path to take (shared by processWithdrawCustom and preview)
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param amount0Desired Amount of token0 to withdraw
     * @param amount1Desired Amount of token1 to withdraw
     * @return info Withdrawal path information
     */
    function determineWithdrawPath(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (WithdrawPathInfo memory info) {
        // Get totals
        (info.total0, info.total1, info.totalFee0, info.totalFee1) = getTotalAmounts(s, poolManager);

        // Get current balances
        info.currentBalance0 = s.currency0.balanceOfSelf();
        info.currentBalance1 = s.currency1.balanceOfSelf();

        // PATH 1: Current balance sufficient
        if (info.currentBalance0 >= amount0Desired && info.currentBalance1 >= amount1Desired) {
            info.path = WithdrawPath.USE_CURRENT_BALANCE;
            return info;
        }

        // PATH 2: Balance + fees sufficient
        uint256 availableWithFees0 = info.currentBalance0 + info.totalFee0;
        uint256 availableWithFees1 = info.currentBalance1 + info.totalFee1;

        if (availableWithFees0 >= amount0Desired && availableWithFees1 >= amount1Desired) {
            info.path = WithdrawPath.USE_BALANCE_PLUS_FEES;
            return info;
        }

        // PATH 3: Need to burn and rebalance
        info.path = WithdrawPath.BURN_AND_WITHDRAW;
    }

    /**
     * @notice Process a standard withdrawal
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param shares Number of shares to burn
     * @param to Recipient address
     * @param outMin Minimum output amounts per position
     * @param totalSupply Current total supply
     * @param sender Address of the caller
     * @param withdrawToWallet If true, transfers tokens to 'to'. If false, keeps tokens in contract.
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
    function processWithdraw(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 shares,
        address to,
        uint256[2][] memory outMin,
        uint256 totalSupply,
        address sender,
        bool withdrawToWallet
    ) external returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert ZeroValue();
        if (withdrawToWallet && to == address(0)) revert ZeroAddress();
        if (outMin.length != s.basePositionsLength + s.limitPositionsLength) revert OutMinLengthMismatch();

        // Execute withdrawal via callback
        {
            bytes memory params = abi.encode(shares, outMin);
            bytes memory result = poolManager.unlock(abi.encode(IMultiPositionManager.Action.WITHDRAW, params));
            (amount0, amount1) = abi.decode(result, (uint256, uint256));
        }

        // Calculate and transfer unused amounts only if withdrawing to wallet
        if (withdrawToWallet) {
            // Transfer withdrawn amounts
            if (amount0 != 0) s.currency0.transfer(to, amount0);
            if (amount1 != 0) s.currency1.transfer(to, amount1);

            // Calculate and transfer unused amounts in a scoped block
            {
                uint256 unusedAmount0 = FullMath.mulDiv(s.currency0.balanceOfSelf(), shares, totalSupply);
                uint256 unusedAmount1 = FullMath.mulDiv(s.currency1.balanceOfSelf(), shares, totalSupply);

                if (unusedAmount0 != 0) {
                    unchecked {
                        amount0 += unusedAmount0;
                    }
                    s.currency0.transfer(to, unusedAmount0);
                }
                if (unusedAmount1 != 0) {
                    unchecked {
                        amount1 += unusedAmount1;
                    }
                    s.currency1.transfer(to, unusedAmount1);
                }
            }

            // Note: Main contract will handle burning shares
            emit Withdraw(sender, to, shares, amount0, amount1);
        } else {
            // For non-wallet withdrawals, just calculate unused amounts for reporting
            {
                uint256 unusedAmount0 = FullMath.mulDiv(s.currency0.balanceOfSelf() - amount0, shares, totalSupply);
                uint256 unusedAmount1 = FullMath.mulDiv(s.currency1.balanceOfSelf() - amount1, shares, totalSupply);

                unchecked {
                    amount0 += unusedAmount0;
                    amount1 += unusedAmount1;
                }
            }

            // Tokens stay in contract, emit Burn event
            emit Burn(sender, shares, totalSupply, amount0, amount1);
        }
    }

    /**
     * @notice Helper function to transfer tokens
     */
    function _transferWithdrawCustom(
        SharedStructs.ManagerStorage storage s,
        address to,
        uint256 amount0Out,
        uint256 amount1Out
    ) private {
        if (amount0Out != 0) {
            s.currency0.transfer(to, amount0Out);
        }
        if (amount1Out != 0) {
            s.currency1.transfer(to, amount1Out);
        }
    }

    /**
     * @notice Helper function to transfer tokens and emit event
     */
    function _transferAndEmitWithdrawCustom(
        SharedStructs.ManagerStorage storage s,
        address sender,
        address to,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 sharesBurned
    ) private {
        _transferWithdrawCustom(s, to, amount0Out, amount1Out);
        emit WithdrawCustom(sender, to, sharesBurned, amount0Out, amount1Out);
    }

    /**
     * @notice Process a custom withdrawal (both tokens)
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param params Withdrawal parameters bundled to reduce stack depth
     * @return amount0Out Amount of token0 withdrawn
     * @return amount1Out Amount of token1 withdrawn
     * @return sharesBurned Number of shares to burn
     */
    function processWithdrawCustom(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        CustomWithdrawParams memory params
    ) external returns (uint256 amount0Out, uint256 amount1Out, uint256 sharesBurned) {
        if (params.to == address(0)) revert InvalidRecipient();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert AmountMustBePositive();

        // Determine withdrawal path using shared helper
        WithdrawPathInfo memory pathInfo =
            determineWithdrawPath(s, poolManager, params.amount0Desired, params.amount1Desired);

        // Check if requested amounts exceed total available
        if (params.amount0Desired > pathInfo.total0) revert InsufficientBalance();
        if (params.amount1Desired > pathInfo.total1) revert InsufficientBalance();

        // Calculate shares to burn based on combined withdrawal value
        {
            sharesBurned = calculateSharesToBurn(
                s,
                poolManager,
                params.amount0Desired,
                params.amount1Desired,
                params.totalSupply,
                pathInfo.total0,
                pathInfo.total1
            );
            if (sharesBurned > params.senderBalance) revert InsufficientBalance();
        }

        // Execute withdrawal based on path
        if (pathInfo.path == WithdrawPath.USE_CURRENT_BALANCE) {
            // Step 1: Direct transfer from current balance
            amount0Out = params.amount0Desired;
            amount1Out = params.amount1Desired;
            _transferAndEmitWithdrawCustom(s, params.sender, params.to, amount0Out, amount1Out, sharesBurned);
            return (amount0Out, amount1Out, sharesBurned);
        }

        if (pathInfo.path == WithdrawPath.USE_BALANCE_PLUS_FEES) {
            // Step 2: Collect fees via unlock callback, then transfer
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.ZERO_BURN, ""));
            amount0Out = params.amount0Desired;
            amount1Out = params.amount1Desired;
            _transferAndEmitWithdrawCustom(s, params.sender, params.to, amount0Out, amount1Out, sharesBurned);
            return (amount0Out, amount1Out, sharesBurned);
        }

        // Step 3: Partial position burn to get sufficient assets
        // Calculate how much of positions to burn
        uint256 positionSharesToBurn = calculatePositionSharesToBurn(
            s, poolManager, params.amount0Desired, params.amount1Desired, params.totalSupply
        );

        // Execute partial withdrawal using standard WITHDRAW action
        bytes memory withdrawParams = abi.encode(positionSharesToBurn, params.outMin);
        poolManager.unlock(abi.encode(IMultiPositionManager.Action.WITHDRAW, withdrawParams));

        // The WITHDRAW action has:
        // 1. Collected ALL fees from positions
        // 2. Burned liquidity pro-rata
        // 3. Taken pro-rata share of unused balance

        // Get balances after burn
        uint256 balance0 = s.currency0.balanceOfSelf();
        uint256 balance1 = s.currency1.balanceOfSelf();

        // Transfer actual balance when short due to rounding, otherwise transfer requested amount
        amount0Out = balance0 < params.amount0Desired ? balance0 : params.amount0Desired;
        amount1Out = balance1 < params.amount1Desired ? balance1 : params.amount1Desired;
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientBalance();
        _transferWithdrawCustom(s, params.to, amount0Out, amount1Out);

        // NO REBALANCING - excess remains as unused balance

        emit WithdrawCustom(params.sender, params.to, sharesBurned, amount0Out, amount1Out);
        return (amount0Out, amount1Out, sharesBurned);
    }

    /**
     * @notice Calculate minimum shares worth of positions to burn to get desired amounts
     * @dev PUBLIC so SimpleLens can call it directly
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param amount0Desired Amount of token0 needed
     * @param amount1Desired Amount of token1 needed
     * @param totalSupply Total supply of shares
     * @return positionShares Shares worth of positions to burn
     */
    function calculatePositionSharesToBurn(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 totalSupply
    ) internal view returns (uint256 positionShares) {
        if (totalSupply == 0) revert NoSharesExist();

        // Get total amounts (positions + fees + unused balances)
        (uint256 total0, uint256 total1,,) = getTotalAmounts(s, poolManager);

        // Calculate shares needed for each token (ceiling division for safety)
        uint256 sharesForToken0;
        uint256 sharesForToken1;

        if (amount0Desired != 0 && total0 != 0) {
            // Ceiling division
            unchecked {
                sharesForToken0 = (amount0Desired * totalSupply + total0 - 1) / total0;
            }
        }

        if (amount1Desired != 0 && total1 != 0) {
            unchecked {
                sharesForToken1 = (amount1Desired * totalSupply + total1 - 1) / total1;
            }
        }

        // Take maximum to ensure both requirements met
        positionShares = sharesForToken0 > sharesForToken1 ? sharesForToken0 : sharesForToken1;

        // Cap at total supply
        if (positionShares > totalSupply) {
            positionShares = totalSupply;
        }
    }

    /**
     * @notice Calculate shares to burn for custom withdrawal (both tokens)
     */
    function calculateSharesToBurn(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 totalSupply,
        uint256 pool0,
        uint256 pool1
    ) internal view returns (uint256 shares) {
        if (totalSupply == 0) revert NoSharesExist();

        // Get current price from pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(s.poolKey.toId());

        // Calculate price of token0 in terms of token1 with PRECISION
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        // Calculate total withdrawal value in token1 terms (combining both tokens)
        uint256 withdrawalValue0InToken1 = FullMath.mulDiv(amount0Desired, price, PRECISION);
        uint256 withdrawalValueInToken1;
        uint256 poolValueInToken1;

        unchecked {
            withdrawalValueInToken1 = withdrawalValue0InToken1 + amount1Desired;
            // Calculate pool value in token1 terms
            poolValueInToken1 = pool1 + FullMath.mulDiv(pool0, price, PRECISION);
        }

        if (poolValueInToken1 == 0) {
            // Fallback to token0 terms if token1 valuation rounds to zero
            uint256 withdrawalValueInToken0 = amount0Desired;
            uint256 poolValueInToken0 = pool0;

            if (price == 0) {
                if (amount1Desired != 0 || pool1 != 0) revert InsufficientBalance();
            } else {
                if (amount1Desired != 0) {
                    unchecked {
                        withdrawalValueInToken0 += FullMath.mulDiv(amount1Desired, PRECISION, price);
                    }
                }
                if (pool1 != 0) {
                    unchecked {
                        poolValueInToken0 += FullMath.mulDiv(pool1, PRECISION, price);
                    }
                }
            }

            shares = FullMath.mulDiv(withdrawalValueInToken0, totalSupply, poolValueInToken0);
        } else {
            // Calculate shares to burn
            shares = FullMath.mulDiv(withdrawalValueInToken1, totalSupply, poolValueInToken1);
        }

        if (shares == 0 && (amount0Desired != 0 || amount1Desired != 0)) {
            shares = 1;
        }
    }

    /**
     * @notice Public wrapper for calculateSharesToBurn that works with MultiPositionManager
     * @param manager The MultiPositionManager contract
     * @param amount0Desired Amount of token0 desired to withdraw
     * @param amount1Desired Amount of token1 desired to withdraw
     * @param totalSupply Total supply of vault shares
     * @param pool0 Total amount of token0 in pool
     * @param pool1 Total amount of token1 in pool
     * @return shares Number of shares to burn
     */
    function calculateSharesToBurnForManager(
        address manager,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 totalSupply,
        uint256 pool0,
        uint256 pool1
    ) external view returns (uint256 shares) {
        if (totalSupply == 0) revert NoSharesExist();

        // Get manager's pool key and pool manager using interface
        IMultiPositionManager mpm = IMultiPositionManager(manager);
        IPoolManager poolManager = mpm.poolManager();
        PoolKey memory poolKey = mpm.poolKey();

        // Get current price from pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Calculate price of token0 in terms of token1 with PRECISION
        uint256 price =
            FullMath.mulDiv(FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), PRECISION, 1 << 96);

        // Calculate total withdrawal value in token1 terms (combining both tokens)
        uint256 withdrawalValue0InToken1 = FullMath.mulDiv(amount0Desired, price, PRECISION);
        uint256 withdrawalValueInToken1;
        uint256 poolValueInToken1;

        unchecked {
            withdrawalValueInToken1 = withdrawalValue0InToken1 + amount1Desired;
            // Calculate pool value in token1 terms
            poolValueInToken1 = pool1 + FullMath.mulDiv(pool0, price, PRECISION);
        }

        if (poolValueInToken1 == 0) {
            // Fallback to token0 terms if token1 valuation rounds to zero
            uint256 withdrawalValueInToken0 = amount0Desired;
            uint256 poolValueInToken0 = pool0;

            if (price == 0) {
                if (amount1Desired != 0 || pool1 != 0) revert InsufficientBalance();
            } else {
                if (amount1Desired != 0) {
                    unchecked {
                        withdrawalValueInToken0 += FullMath.mulDiv(amount1Desired, PRECISION, price);
                    }
                }
                if (pool1 != 0) {
                    unchecked {
                        poolValueInToken0 += FullMath.mulDiv(pool1, PRECISION, price);
                    }
                }
            }

            shares = FullMath.mulDiv(withdrawalValueInToken0, totalSupply, poolValueInToken0);
        } else {
            // Calculate shares to burn
            shares = FullMath.mulDiv(withdrawalValueInToken1, totalSupply, poolValueInToken1);
        }

        if (shares == 0 && (amount0Desired != 0 || amount1Desired != 0)) {
            shares = 1;
        }
    }

    /**
     * @notice Public wrapper for calculatePositionSharesToBurn for SimpleLens
     * @param manager The MultiPositionManager contract address
     * @param amount0Desired Amount of token0 needed
     * @param amount1Desired Amount of token1 needed
     * @return positionShares Shares worth of positions to burn
     */
    function calculatePositionSharesToBurnForSimpleLens(address manager, uint256 amount0Desired, uint256 amount1Desired)
        external
        view
        returns (uint256 positionShares)
    {
        IMultiPositionManager mpm = IMultiPositionManager(manager);

        uint256 totalSupply = mpm.totalSupply();
        if (totalSupply == 0) revert NoSharesExist();

        // Get total amounts using the interface
        (uint256 total0, uint256 total1,,) = mpm.getTotalAmounts();

        // Calculate shares needed for each token (ceiling division for safety)
        uint256 sharesForToken0;
        uint256 sharesForToken1;

        if (amount0Desired != 0 && total0 != 0) {
            // Ceiling division
            unchecked {
                sharesForToken0 = (amount0Desired * totalSupply + total0 - 1) / total0;
            }
        }

        if (amount1Desired != 0 && total1 != 0) {
            unchecked {
                sharesForToken1 = (amount1Desired * totalSupply + total1 - 1) / total1;
            }
        }

        // Take maximum to ensure both requirements met
        positionShares = sharesForToken0 > sharesForToken1 ? sharesForToken0 : sharesForToken1;

        // Cap at total supply
        if (positionShares > totalSupply) {
            positionShares = totalSupply;
        }
    }

    /**
     * @notice Claim accumulated fees to the fee recipient (internal helper)
     * @param poolManager Pool manager contract
     * @param factory Factory contract address to get fee recipient
     * @param currency Currency to claim fees for
     */
    function _claimFeeCurrency(IPoolManager poolManager, address factory, Currency currency) internal {
        uint256 amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        // Get feeRecipient from factory
        address recipient = IMultiPositionFactory(factory).feeRecipient();
        poolManager.take(currency, recipient, amount);
    }

    /**
     * @notice Claim accumulated fees to the fee recipient (external)
     * @param poolManager Pool manager contract
     * @param factory Factory contract address to get fee recipient
     * @param currency Currency to claim fees for
     */
    function claimFee(IPoolManager poolManager, address factory, Currency currency) external {
        _claimFeeCurrency(poolManager, factory, currency);
    }

    /**
     * @notice Process claim fee action - collects fees and distributes to owner and treasury
     * @param s Storage pointer
     * @param poolManager Pool manager contract
     * @param caller Address initiating the claim
     * @param owner Owner address
     */
    function processClaimFee(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        address caller,
        address owner
    ) external {
        // If owner is calling, perform zeroBurn to collect new fees
        if (caller == owner) {
            // Perform zeroBurn and get the exact fee amounts
            (uint256 totalFee0, uint256 totalFee1) = zeroBurnAllWithoutUnlock(s, poolManager);

            // After zeroBurnAll, treasury portion is minted as ERC-6909 to contract
            // The owner's portion creates negative deltas that are settled by close
            PoolManagerUtils.close(poolManager, s.currency1);
            PoolManagerUtils.close(poolManager, s.currency0);

            // Calculate exact splits
            uint256 treasuryFee0;
            uint256 treasuryFee1;
            uint256 ownerFee0;
            uint256 ownerFee1;

            unchecked {
                treasuryFee0 = totalFee0 / s.fee;
                treasuryFee1 = totalFee1 / s.fee;
                ownerFee0 = totalFee0 - treasuryFee0;
                ownerFee1 = totalFee1 - treasuryFee1;
            }

            // Transfer owner's portion (now in contract after close)
            if (ownerFee0 != 0) {
                if (s.currency0.isAddressZero()) {
                    // Native token - transfer ETH
                    s.currency0.transfer(owner, ownerFee0);
                } else {
                    // ERC20 token
                    IERC20(Currency.unwrap(s.currency0)).safeTransfer(owner, ownerFee0);
                }
            }
            if (ownerFee1 != 0) {
                // Currency1 is never native, always ERC20
                IERC20(Currency.unwrap(s.currency1)).safeTransfer(owner, ownerFee1);
            }
        }

        // Always transfer treasury portion to fee recipient
        // For protocol fee claims (caller == address(0)), this just transfers existing balance
        // For owner claims, this transfers the freshly collected treasury portion
        _claimFeeCurrency(poolManager, s.factory, s.currency0);
        _claimFeeCurrency(poolManager, s.factory, s.currency1);
    }

    /**
     * @notice Get total amounts including fees
     */
    function getTotalAmounts(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        internal
        view
        returns (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1)
    {
        // Get amounts from base positions
        for (uint8 i = 0; i < s.basePositionsLength;) {
            (, uint256 amount0, uint256 amount1, uint256 feesOwed0, uint256 feesOwed1) =
                PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, s.basePositions[i]);
            unchecked {
                total0 += amount0;
                total1 += amount1;
                totalFee0 += feesOwed0;
                totalFee1 += feesOwed1;
                ++i;
            }
        }

        // Get amounts from limit positions
        for (uint8 i = 0; i < 2;) {
            IMultiPositionManager.Range memory limitRange = s.limitPositions[i];
            if (limitRange.lowerTick != limitRange.upperTick) {
                (, uint256 amount0, uint256 amount1, uint256 feesOwed0, uint256 feesOwed1) =
                    PoolManagerUtils.getAmountsOf(poolManager, s.poolKey, limitRange);
                unchecked {
                    total0 += amount0;
                    total1 += amount1;
                    totalFee0 += feesOwed0;
                    totalFee1 += feesOwed1;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Exclude protocol fee from the total amount
        unchecked {
            totalFee0 -= (totalFee0 / s.fee);
            totalFee1 -= (totalFee1 / s.fee);

            // Add fees net of protocol fees to the total amount
            total0 += totalFee0;
            total1 += totalFee1;

            // Add unused balances
            total0 += s.currency0.balanceOfSelf();
            total1 += s.currency1.balanceOfSelf();
        }
    }

    /**
     * @notice Process BURN_ALL action in callback
     * @dev Burns all positions and clears storage
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @param totalSupply Current total supply
     * @param params Encoded parameters (outMin array)
     * @return Encoded burned amounts (amount0, amount1)
     */
    function processBurnAllInCallback(
        SharedStructs.ManagerStorage storage s,
        IPoolManager poolManager,
        uint256 totalSupply,
        bytes memory params
    ) external returns (bytes memory) {
        // Decode parameters
        uint256[2][] memory outMin = abi.decode(params, (uint256[2][]));

        // Calculate fees owed before burning liquidity (burning clears fee growth state)
        uint256 totalFee0;
        uint256 totalFee1;
        {
            uint256 baseLength = s.basePositionsLength;
            IMultiPositionManager.Range[] memory baseRangesArray = new IMultiPositionManager.Range[](baseLength);
            for (uint8 i = 0; i < baseLength;) {
                baseRangesArray[i] = s.basePositions[i];
                unchecked {
                    ++i;
                }
            }

            IMultiPositionManager.Range[2] memory limitRangesArray;
            limitRangesArray[0] = s.limitPositions[0];
            limitRangesArray[1] = s.limitPositions[1];

            (totalFee0, totalFee1) =
                PoolManagerUtils.getTotalFeesOwed(poolManager, s.poolKey, baseRangesArray, limitRangesArray);
        }

        // Burn all positions
        (uint256 amount0, uint256 amount1) =
            PositionLogic.burnLiquidities(poolManager, s, totalSupply, totalSupply, outMin);

        // Mint protocol fee claims based on total fees collected
        uint256 treasuryFee0 = totalFee0 / s.fee;
        uint256 treasuryFee1 = totalFee1 / s.fee;

        if (treasuryFee0 != 0) {
            poolManager.mint(address(this), uint256(uint160(Currency.unwrap(s.currency0))), treasuryFee0);
        }
        if (treasuryFee1 != 0) {
            poolManager.mint(address(this), uint256(uint160(Currency.unwrap(s.currency1))), treasuryFee1);
        }

        // Clear position storage
        s.basePositionsLength = 0;
        delete s.limitPositions[0];
        delete s.limitPositions[1];
        s.limitPositionsLength = 0;

        // Return burned amounts
        return abi.encode(amount0, amount1);
    }

    /**
     * @notice Zero burn all positions without unlock to collect fees
     * @dev Collects fees from all positions without burning liquidity
     * @param s Storage struct
     * @param poolManager Pool manager contract
     * @return totalFee0 Total fees collected in token0
     * @return totalFee1 Total fees collected in token1
     */
    function zeroBurnAllWithoutUnlock(SharedStructs.ManagerStorage storage s, IPoolManager poolManager)
        public
        returns (uint256 totalFee0, uint256 totalFee1)
    {
        // Build base positions array inline to avoid cross-library storage parameter issues
        uint256 baseLength = s.basePositionsLength;
        IMultiPositionManager.Range[] memory baseRangesArray = new IMultiPositionManager.Range[](baseLength);
        for (uint8 i = 0; i < baseLength;) {
            baseRangesArray[i] = s.basePositions[i];
            unchecked {
                ++i;
            }
        }

        // Build limit positions array inline
        IMultiPositionManager.Range[2] memory limitRangesArray;
        limitRangesArray[0] = s.limitPositions[0];
        limitRangesArray[1] = s.limitPositions[1];

        // Collect fees from all positions
        (totalFee0, totalFee1) = PoolManagerUtils.zeroBurnAll(
            poolManager, s.poolKey, baseRangesArray, limitRangesArray, s.currency0, s.currency1, s.fee
        );
    }
}
