// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {IMultiPositionManager} from "../src/MultiPositionManager/interfaces/IMultiPositionManager.sol";
import {SimpleLens} from "../src/MultiPositionManager/periphery/SimpleLens.sol";
import {InitialDepositLens} from "../src/MultiPositionManager/periphery/InitialDepositLens.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployMultiPositionManager is Script {
    struct DeployParams {
        address factory;
        address lens;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        string name;
        address strategy;
        uint256 token0Amount;
        string volatilityStrategy;
        bool useCarpet;
        uint256 maxSlippageBps;
    }

    // Simplified run with defaults: ExponentialStrategy, no hooks, no carpet, 50 bps slippage
    function run(
        address factory,
        address lens,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        string memory name,
        uint256 token0Amount,
        string memory volatilityStrategy
    ) public returns (address) {
        DeployParams memory p;
        p.factory = factory;
        p.lens = lens;
        p.token0 = token0;
        p.token1 = token1;
        p.fee = fee;
        p.tickSpacing = tickSpacing;
        p.hooks = address(0);
        p.name = name;
        p.strategy = 0x22F904c932D1B00ff19819a6B2FbaDD5dC5A0199; // ExponentialStrategy
        p.token0Amount = token0Amount;
        p.volatilityStrategy = volatilityStrategy;
        p.useCarpet = false;
        p.maxSlippageBps = 10000;

        return run(p);
    }

    function run(DeployParams memory p) public returns (address) {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(p.token0),
            currency1: Currency.wrap(p.token1),
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(p.hooks)
        });

        (uint24 tL, uint24 tR) = _getTicks(p.volatilityStrategy, p.tickSpacing);
        address futureAddr = MultiPositionFactory(p.factory).computeAddress(poolKey, deployer, p.name);

        (uint256 token1Amt, uint256[2][] memory inMin) = _calcAmounts(p, poolKey, tL, tR);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        if (p.token0 != address(0)) IERC20(p.token0).approve(futureAddr, p.token0Amount);
        if (p.token1 != address(0)) IERC20(p.token1).approve(futureAddr, token1Amt);

        address deployed = _executeDeploy(p, poolKey, deployer, token1Amt, tL, tR, inMin);

        vm.stopBroadcast();

        console.log("Deployed:", deployed);
        return deployed;
    }

    function _calcAmounts(DeployParams memory p, PoolKey memory poolKey, uint24 tL, uint24 tR)
        internal
        view
        returns (uint256 token1Amt, uint256[2][] memory inMin)
    {
        InitialDepositLens.InitialDepositParams memory params = InitialDepositLens.InitialDepositParams({
            strategyAddress: p.strategy,
            centerTick: 8388607,
            ticksLeft: tL,
            ticksRight: tR,
            limitWidth: 0,
            weight0: 0,
            weight1: 0,
            useCarpet: p.useCarpet,
            isToken0: true,
            amount: p.token0Amount,
            maxSlippageBps: p.maxSlippageBps
        });
        (token1Amt, inMin,) = InitialDepositLens(p.lens).getAmountsForInitialDepositAndPreviewRebalance(poolKey, params);
    }

    function _executeDeploy(
        DeployParams memory p,
        PoolKey memory poolKey,
        address deployer,
        uint256 token1Amt,
        uint24 tL,
        uint24 tR,
        uint256[2][] memory inMin
    ) internal returns (address) {
        uint256 ethVal = (p.token0 == address(0)) ? p.token0Amount : (p.token1 == address(0)) ? token1Amt : 0;

        IMultiPositionManager.RebalanceParams memory rbParams = IMultiPositionManager.RebalanceParams({
            strategy: p.strategy,
            center: 8388607,
            tLeft: tL,
            tRight: tR,
            limitWidth: 0,
            weight0: 0,
            weight1: 0,
            useCarpet: p.useCarpet
        });

        return MultiPositionFactory(p.factory).deployDepositAndRebalance{value: ethVal}(
            poolKey, deployer, p.name, p.token0Amount, token1Amt, deployer, inMin, rbParams
        );
    }

    function _getTicks(string memory s, int24 ts) internal pure returns (uint24, uint24) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("narrowStable")) return (10, 10);
        if (h == keccak256("wideStable")) return (25, 25);
        if (h == keccak256("narrowVolatile")) return (500, 500);
        if (h == keccak256("wideVolatile")) return (5000, 5000);
        if (h == keccak256("singleTick")) return (0, uint24(uint256(int256(ts))));
        revert("Invalid");
    }
}
