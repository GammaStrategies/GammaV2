// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {IMultiPositionManager} from "./interfaces/IMultiPositionManager.sol";
import {IMultiPositionFactory} from "./interfaces/IMultiPositionFactory.sol";
import {PoolManagerUtils} from "./libraries/PoolManagerUtils.sol";
import {Multicall} from "./base/Multicall.sol";
import {SharedStructs} from "./base/SharedStructs.sol";
import {RebalanceLogic} from "./libraries/RebalanceLogic.sol";
import {RebalanceSwapLogic} from "./libraries/RebalanceSwapLogic.sol";
import {WithdrawLogic} from "./libraries/WithdrawLogic.sol";
import {DepositLogic} from "./libraries/DepositLogic.sol";
import {PositionLogic} from "./libraries/PositionLogic.sol";

contract MultiPositionManager is IMultiPositionManager, ERC20, ReentrancyGuard, Ownable, SafeCallback, Multicall {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant PRECISION = 1e36;
    int24 public constant CENTER_AT_CURRENT_TICK = type(int24).max;

    event RelayerGranted(address indexed account);
    event RelayerRevoked(address indexed account);

    SharedStructs.ManagerStorage internal s;

    error UnauthorizedCaller();
    error InvalidAction();
    error InvalidFee();
    error OnlyOneNativeDepositPerMulticall();
    error NativeRefundFailed();

    event Withdraw(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 shares, uint256 totalSupply, uint256 amount0, uint256 amount1);

    event WithdrawCustom(
        address indexed sender, address indexed to, uint256 shares, uint256 amount0Out, uint256 amount1Out
    );
    event FeeChanged(uint16 newFee);

    /**
     * @notice Constructor for MultiPositionManager
     * @dev Sets all immutable values and initializes the contract
     * @param _poolManager The Uniswap V4 pool manager
     * @param _poolKey The pool key defining the pool
     * @param _owner The owner address
     * @param _factory The factory address
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _fee The protocol fee denominator
     */
    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        address _owner,
        address _factory,
        string memory _name,
        string memory _symbol,
        uint16 _fee
    ) ERC20(_name, _symbol) Ownable(_owner) SafeCallback(_poolManager) {
        if (_fee == 0) revert InvalidFee();
        s.poolKey = _poolKey;
        s.poolId = _poolKey.toId();
        s.currency0 = _poolKey.currency0;
        s.currency1 = _poolKey.currency1;
        s.factory = _factory;
        s.fee = _fee;
    }

    function poolKey() external view returns (PoolKey memory) {
        return s.poolKey;
    }

    function fee() external view returns (uint16) {
        return s.fee;
    }

    function factory() external view returns (address) {
        return s.factory;
    }

    function basePositionsLength() external view returns (uint256) {
        return s.basePositionsLength;
    }

    function limitPositions(uint256 index) external view returns (Range memory) {
        return s.limitPositions[index];
    }

    function limitPositionsLength() external view returns (uint256) {
        return s.limitPositionsLength;
    }

    function lastStrategyParams()
        external
        view
        returns (
            address strategy,
            int24 centerTick,
            uint24 ticksLeft,
            uint24 ticksRight,
            uint24 limitWidth,
            uint120 weight0,
            uint120 weight1,
            bool useCarpet,
            bool useSwap,
            bool useAssetWeights
        )
    {
        SharedStructs.StrategyParams memory params = s.lastStrategyParams;
        return (
            params.strategy,
            params.centerTick,
            params.ticksLeft,
            params.ticksRight,
            params.limitWidth,
            params.weight0,
            params.weight1,
            params.useCarpet,
            params.useSwap,
            params.useAssetWeights
        );
    }

    function isRelayer(address account) public view returns (bool) {
        return s.relayers[account];
    }

    modifier onlyOwnerOrFactory() {
        require(msg.sender == owner() || msg.sender == s.factory);
        _;
    }

    modifier onlyOwnerOrRelayerOrFactory() {
        require(msg.sender == owner() || s.relayers[msg.sender] || msg.sender == s.factory);
        _;
    }

    receive() external payable {}

    /**
     * @notice Deposit tokens to vault (idle balance). Use compound() to add to positions.
     * @param deposit0Desired Maximum amount of token0 to deposit
     * @param deposit1Desired Maximum amount of token1 to deposit
     * @param to Address to receive shares
     * @param from Address to pull tokens from
     * @return shares Number of shares minted
     * @return deposit0 Actual amount of token0 deposited
     * @return deposit1 Actual amount of token1 deposited
     * @dev Tokens are pulled from 'from' and shares are minted to 'to'
     */
    function deposit(uint256 deposit0Desired, uint256 deposit1Desired, address to, address from)
        external
        payable
        onlyOwnerOrFactory
        nonReentrant
        returns (uint256 shares, uint256 deposit0, uint256 deposit1)
    {
        (shares, deposit0, deposit1) = DepositLogic.processDeposit(
            s,
            poolManager,
            deposit0Desired,
            deposit1Desired,
            to, // shares minted to 'to'
            from, // tokens pulled from 'from'
            totalSupply(),
            msg.value
        );

        _mint(to, shares);
        _transferIn(from, s.currency0, deposit0);
        _transferIn(from, s.currency1, deposit1);
    }

    /**
     * @notice Compound idle vault balance + fees into existing positions
     * @dev Collects fees via zeroBurn, then adds all idle balance to positions
     *      Marked payable for multicall compatibility - msg.value persists across delegatecalls.
     *      Does not consume msg.value; it just needs to accept it to prevent multicall reverts.
     * @param inMin Minimum amounts for each position (slippage protection)
     */
    function compound(uint256[2][] calldata inMin) external payable onlyOwnerOrRelayerOrFactory {
        // First call ZERO_BURN to collect fees without unlock
        if (s.basePositionsLength > 0) {
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.ZERO_BURN, ""));
        }

        // Then call COMPOUND to redeposit collected fees
        poolManager.unlock(abi.encode(IMultiPositionManager.Action.COMPOUND, abi.encode(inMin)));
    }

    /**
     * @notice Compound with swap: collect fees, swap to target ratio, then add to positions
     * @param swapParams Swap parameters for DEX aggregator execution
     * @param inMin Minimum amounts per position for slippage protection
     */
    function compoundSwap(RebalanceLogic.SwapParams calldata swapParams, uint256[2][] calldata inMin)
        external
        payable
        onlyOwnerOrRelayerOrFactory
    {
        if (s.basePositionsLength > 0) {
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.ZERO_BURN, ""));
        }

        RebalanceSwapLogic.executeCompoundSwap(s, swapParams);

        poolManager.unlock(abi.encode(IMultiPositionManager.Action.COMPOUND, abi.encode(inMin)));
    }

    /**
     * @notice Withdraw shares from the vault
     * @param shares Number of liquidity tokens to redeem as pool assets
     * @param outMin min amount returned for shares of liq
     * @param withdrawToWallet If true, transfers tokens and burns shares. If false, keeps tokens in contract and preserves shares.
     * @return amount0 Amount of token0 redeemed by the submitted liquidity tokens
     * @return amount1 Amount of token1 redeemed by the submitted liquidity tokens
     * @dev Manager calls (owner/relayer/factory) send tokens to owner. Share holders can only withdraw to their own wallet.
     */
    function withdraw(uint256 shares, uint256[2][] memory outMin, bool withdrawToWallet)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        bool isManager = msg.sender == owner() || s.relayers[msg.sender] || msg.sender == s.factory;
        address recipient = owner();

        if (!isManager) {
            if (!withdrawToWallet) revert UnauthorizedCaller();
            if (balanceOf(msg.sender) < shares) revert WithdrawLogic.InsufficientBalance();
            recipient = msg.sender;
        }

        (amount0, amount1) = WithdrawLogic.processWithdraw(
            s,
            poolManager,
            shares,
            recipient,
            outMin,
            totalSupply(),
            msg.sender,
            withdrawToWallet
        );

        if (withdrawToWallet) {
            _burn(recipient, shares);
            if (totalSupply() == 0) {
                s.basePositionsLength = 0;
                delete s.limitPositions[0];
                delete s.limitPositions[1];
                s.limitPositionsLength = 0;
            }
        }
    }

    /**
     * @notice Withdraw custom amounts of both tokens
     * @param amount0Desired Amount of token0 to withdraw
     * @param amount1Desired Amount of token1 to withdraw
     * @param outMin Minimum amounts per position for slippage protection
     * @return amount0Out Amount of token0 withdrawn
     * @return amount1Out Amount of token1 withdrawn
     * @return sharesBurned Number of shares burned
     * @dev Tokens are always sent to owner
     */
    function withdrawCustom(uint256 amount0Desired, uint256 amount1Desired, uint256[2][] memory outMin)
        external
        nonReentrant
        onlyOwnerOrRelayerOrFactory
        returns (uint256 amount0Out, uint256 amount1Out, uint256 sharesBurned)
    {
        WithdrawLogic.CustomWithdrawParams memory params = WithdrawLogic.CustomWithdrawParams({
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            to: owner(), // tokens always go to owner
            outMin: outMin,
            totalSupply: totalSupply(),
            senderBalance: balanceOf(owner()),
            sender: owner()
        });

        (amount0Out, amount1Out, sharesBurned) = WithdrawLogic.processWithdrawCustom(s, poolManager, params);
        _burn(owner(), sharesBurned);
        if (totalSupply() == 0) {
            s.basePositionsLength = 0;
            delete s.limitPositions[0];
            delete s.limitPositions[1];
            s.limitPositionsLength = 0;
        }
    }

    /**
     * @notice Unified rebalance function with optional weighted token distribution
     * @param params Rebalance parameters including optional weights
     * @param outMin Minimum output amounts for withdrawals
     * @param inMin Minimum input amounts for new positions (slippage protection)
     * @dev If weights are not specified or are both 0, defaults to 50/50 distribution
     *      Marked payable for multicall compatibility - msg.value persists across delegatecalls.
     *      Does not consume msg.value; it just needs to accept it to prevent multicall reverts.
     */
    function rebalance(
        IMultiPositionManager.RebalanceParams calldata params,
        uint256[2][] memory outMin,
        uint256[2][] memory inMin
    ) public payable onlyOwnerOrRelayerOrFactory {
        // First call ZERO_BURN to collect fees (like compound does)
        if (s.basePositionsLength > 0 || s.limitPositionsLength > 0) {
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.ZERO_BURN, ""));
        }

        // Now fees are in balanceOfSelf(), so liquidities will be calculated correctly
        (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory liquidities, uint24 limitWidth) =
            RebalanceLogic.rebalance(s, poolManager, params, outMin);

        bytes memory encodedParams = abi.encode(baseRanges, liquidities, limitWidth, inMin, outMin, params);
        poolManager.unlock(abi.encode(IMultiPositionManager.Action.REBALANCE, encodedParams));
    }

    /**
     * @notice Rebalances positions with an external DEX swap to achieve target weights
     * @param params Swap and rebalance parameters including aggregator address and swap data
     * @param outMin Minimum output amounts for burning current positions
     * @param inMin Minimum input amounts for new positions (slippage protection)
     * @dev Burns all positions first, then swaps to target ratio, then rebalances with new amounts
     */
    function rebalanceSwap(
        IMultiPositionManager.RebalanceSwapParams calldata params,
        uint256[2][] memory outMin,
        uint256[2][] memory inMin
    ) public payable onlyOwnerOrRelayerOrFactory {
        if (totalSupply() > 0 && (s.basePositionsLength > 0 || s.limitPositionsLength > 0)) {
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.BURN_ALL, abi.encode(outMin)));
        }

        (IMultiPositionManager.Range[] memory baseRanges, uint128[] memory liquidities, uint24 limitWidth) =
            RebalanceSwapLogic.executeSwapAndCalculateRanges(s, poolManager, params);

        bytes memory encodedParams =
            abi.encode(baseRanges, liquidities, limitWidth, inMin, outMin, params.rebalanceParams);
        poolManager.unlock(abi.encode(IMultiPositionManager.Action.REBALANCE, encodedParams));
    }

    /**
     * @notice Claims fees
     * @dev If called by owner or relayer, performs zeroBurn and claims fees (owner fees go to owner)
     * @dev If called by factory owner or CLAIM_MANAGER, only claims existing protocol fees
     */
    function claimFee() external {
        if (msg.sender == owner() || s.relayers[msg.sender]) {
            // Owner or relayer calling - collect fees and transfer owner portion to owner
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.CLAIM_FEE, abi.encode(owner())));
        } else if (
            IMultiPositionFactory(s.factory).hasRoleOrOwner(
                IMultiPositionFactory(s.factory).CLAIM_MANAGER(), msg.sender
            )
        ) {
            // CLAIM_MANAGER calling - only claim protocol fees
            poolManager.unlock(abi.encode(IMultiPositionManager.Action.CLAIM_FEE, abi.encode(address(0))));
        } else {
            revert UnauthorizedCaller();
        }
    }

    function setFee(uint16 newFee) external {
        IMultiPositionFactory factoryContract = IMultiPositionFactory(s.factory);
        require(factoryContract.hasRole(factoryContract.FEE_MANAGER(), msg.sender));
        require(newFee != 0, "Fee cannot be zero");
        s.fee = newFee;
        emit FeeChanged(newFee);
    }

    /**
     * @notice Grant relayer role to an address
     * @param account The address to grant the role to
     */
    function grantRelayerRole(address account) external onlyOwner {
        require(account != address(0));
        IMultiPositionFactory factoryContract = IMultiPositionFactory(s.factory);
        if (factoryContract.hasRoleOrOwner(factoryContract.CLAIM_MANAGER(), account)) {
            revert UnauthorizedCaller();
        }
        if (!s.relayers[account]) {
            s.relayers[account] = true;
            emit RelayerGranted(account);
        }
    }

    /**
     * @notice Revoke relayer role from an address
     * @param account The address to revoke the role from
     */
    function revokeRelayerRole(address account) external onlyOwner {
        if (s.relayers[account]) {
            s.relayers[account] = false;
            emit RelayerRevoked(account);
        }
    }

    function getBasePositions() public view returns (Range[] memory, PositionData[] memory) {
        return PositionLogic.getBasePositions(s, poolManager);
    }

    function getPositions() public view returns (Range[] memory, PositionData[] memory) {
        return PositionLogic.getPositions(s, poolManager);
    }

    function getTotalAmounts()
        external
        view
        returns (uint256 total0, uint256 total1, uint256 totalFee0, uint256 totalFee1)
    {
        return WithdrawLogic.getTotalAmounts(s, poolManager);
    }

    function getTotalValuesInOneToken()
        external
        view
        returns (uint256 totalValueInToken0, uint256 totalValueInToken1)
    {
        return PositionLogic.getTotalValuesInOneToken(s, poolManager);
    }

    function currentTick() public view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(s.poolKey.toId());
    }

    function getRatios()
        external
        view
        returns (
            uint256 pool0Ratio,
            uint256 pool1Ratio,
            uint256 total0Ratio,
            uint256 total1Ratio,
            uint256 inPositionRatio,
            uint256 outOfPositionRatio,
            uint256 baseRatio,
            uint256 limitRatio,
            uint256 base0Ratio,
            uint256 base1Ratio,
            uint256 limit0Ratio,
            uint256 limit1Ratio
        )
    {
        PositionLogic.Ratios memory ratios = PositionLogic.getRatios(s, poolManager);
        return (
            ratios.pool0Ratio,
            ratios.pool1Ratio,
            ratios.total0Ratio,
            ratios.total1Ratio,
            ratios.inPositionRatio,
            ratios.outOfPositionRatio,
            ratios.baseRatio,
            ratios.limitRatio,
            ratios.base0Ratio,
            ratios.base1Ratio,
            ratios.limit0Ratio,
            ratios.limit1Ratio
        );
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (Action selector, bytes memory params) = abi.decode(data, (Action, bytes));
        bytes memory result = _executeActionWithoutUnlock(selector, params);
        _closePair();
        return result;
    }

    function _executeActionWithoutUnlock(Action selector, bytes memory params) internal returns (bytes memory result) {
        if (selector == IMultiPositionManager.Action.WITHDRAW) {
            WithdrawLogic.zeroBurnAllWithoutUnlock(s, poolManager);
            (uint256 shares, uint256[2][] memory outMin) = abi.decode(params, (uint256, uint256[2][]));
            (uint256 amountOut0, uint256 amountOut1) =
                PositionLogic.burnLiquidities(poolManager, s, shares, totalSupply(), outMin);
            return abi.encode(amountOut0, amountOut1);
        } else if (selector == IMultiPositionManager.Action.REBALANCE) {
            return RebalanceLogic.processRebalanceInCallback(s, poolManager, params, totalSupply());
        } else if (selector == IMultiPositionManager.Action.ZERO_BURN) {
            WithdrawLogic.zeroBurnAllWithoutUnlock(s, poolManager);
            return "";
        } else if (selector == IMultiPositionManager.Action.CLAIM_FEE) {
            address caller = abi.decode(params, (address));
            WithdrawLogic.processClaimFee(s, poolManager, caller, owner());
            return "";
        } else if (selector == IMultiPositionManager.Action.BURN_ALL) {
            return WithdrawLogic.processBurnAllInCallback(s, poolManager, totalSupply(), params);
        } else if (selector == IMultiPositionManager.Action.COMPOUND) {
            uint256[2][] memory inMin = abi.decode(params, (uint256[2][]));
            DepositLogic.processCompound(s, poolManager, inMin);
            return "";
        } else {
            revert InvalidAction();
        }
    }

    function _closePair() internal {
        PoolManagerUtils.close(poolManager, s.currency1);
        PoolManagerUtils.close(poolManager, s.currency0);
    }

    function _transferIn(address from, Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // In multicall: only allow ONE native deposit to prevent msg.value double-spend
            if (_inMulticallContext()) {
                if (_isNativeDepositDone()) revert OnlyOneNativeDepositPerMulticall();
                _markNativeDepositDone();
            }
            require(msg.value >= amount);
            if (msg.value > amount) {
                (bool success,) = msg.sender.call{value: msg.value - amount}("");
                if (!success) revert NativeRefundFailed();
            }
        } else if (amount != 0) {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(from, address(this), amount);
        }
    }
}
