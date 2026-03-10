// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MultiPositionFactory} from "../src/MultiPositionManager/MultiPositionFactory.sol";
import {MultiPositionManager} from "../src/MultiPositionManager/MultiPositionManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/**
 * @title Deploy MultiPositionManager through Factory
 * @notice Deploys a new MultiPositionManager for a specific pool using the factory
 *
 * Usage:
 *  forge script script/DeployManager.s.sol:DeployManager \
 *    --rpc-url <UNICHAIN_RPC> \
 *    --broadcast \
 *    --sig "run(address,address,address,uint24,int24,address,address,string,string)" \
 *    <factory> <token0> <token1> <fee> <tickSpacing> <hooks> <owner> <name> <symbol>
 *
 * Example for ETH/USDC pool:
 *  forge script script/DeployManager.s.sol:DeployManager \
 *    --rpc-url https://sepolia.unichain.org \
 *    --broadcast \
 *    --sig "run(address,address,address,uint24,int24,address,address,string,string)" \
 *    0xFactoryAddress \
 *    0x0000000000000000000000000000000000000000 \
 *    0x078D782b760474a361dDA0AF3839290b0EF57AD6 \
 *    500 \
 *    10 \
 *    0x0000000000000000000000000000000000000000 \
 *    0xYourAddress \
 *    "ETH-USDC Gamma LP" \
 *    "ETH-USDC-LP"
 */
contract DeployManager is Script {
    /**
     * @notice Deploy a MultiPositionManager through the factory
     * @param factory The MultiPositionFactory address
     * @param token0 First token address (use 0x0 for native ETH)
     * @param token1 Second token address
     * @param fee Pool fee tier (e.g., 500 for 0.05%, 3000 for 0.3%)
     * @param tickSpacing Pool tick spacing
     * @param hooks Hook contract address (use 0x0 for no hooks)
     * @param owner Manager owner address
     * @param name LP token name
     * @param symbol LP token symbol
     */
    function run(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        address owner,
        string memory name,
        string memory symbol
    ) public returns (address manager) {
        // Validate inputs
        require(factory != address(0), "Factory cannot be zero address");
        require(token1 != address(0), "Token1 cannot be zero address (use token0 for native)");
        require(owner != address(0), "Owner cannot be zero address");
        require(fee > 0, "Fee must be greater than 0");
        require(tickSpacing > 0, "TickSpacing must be greater than 0");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(bytes(symbol).length > 0, "Symbol cannot be empty");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("Deploying MultiPositionManager");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Factory:", factory);
        console.log("\nPool Configuration:");
        console.log(
            "  Token0:", token0 == address(0) ? "ETH (native)" : string(abi.encodePacked("0x", _toHexString(token0)))
        );
        console.log("  Token1:", token1);
        console.log(string(abi.encodePacked("  Fee: ", vm.toString(fee), " (", _formatFeePercentage(fee), ")")));
        console.log("  Tick Spacing:", uint256(uint24(tickSpacing)));
        console.log("  Hooks:", hooks == address(0) ? "None" : string(abi.encodePacked("0x", _toHexString(hooks))));
        console.log("\nManager Configuration:");
        console.log("  Owner:", owner);
        console.log("  Name:", name);
        console.log("  Symbol:", symbol);
        console.log("========================================\n");

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MultiPositionManager through factory
        console.log("Deploying MultiPositionManager through factory...");
        MultiPositionFactory factoryContract = MultiPositionFactory(factory);

        manager = factoryContract.deployMultiPositionManager(poolKey, owner, name);

        console.log("\n[SUCCESS] MultiPositionManager deployed successfully!");
        console.log("  Address:", manager);

        // Get and display manager info
        MultiPositionManager mpm = MultiPositionManager(payable(manager));
        console.log("\nManager Details:");
        console.log("  Owner:", mpm.owner());
        console.log("  Name:", mpm.name());
        console.log("  Symbol:", mpm.symbol());
        console.log("  Fee:", mpm.fee(), "%");
        console.log("  Total Supply:", mpm.totalSupply());

        vm.stopBroadcast();

        _printNextSteps(manager);

        return manager;
    }

    /**
     * @notice Format fee as percentage
     */
    function _formatFeePercentage(uint24 fee) private pure returns (string memory) {
        if (fee == 100) return "0.01%";
        if (fee == 500) return "0.05%";
        if (fee == 3000) return "0.30%";
        if (fee == 10000) return "1.00%";

        // For other fees, calculate percentage
        uint256 percentage = uint256(fee) * 100 / 1000000;
        uint256 decimal = (uint256(fee) * 10000 / 1000000) % 100;

        return string(abi.encodePacked(vm.toString(percentage), ".", vm.toString(decimal), "%"));
    }

    /**
     * @notice Convert address to hex string
     */
    function _toHexString(address addr) private pure returns (string memory) {
        bytes memory data = abi.encodePacked(addr);
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(40);

        for (uint256 i = 0; i < 20; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[1 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }

        return string(str);
    }

    /**
     * @notice Print next steps after deployment
     */
    function _printNextSteps(address manager) private pure {
        console.log("\n========================================");
        console.log("NEXT STEPS");
        console.log("========================================");
        console.log("1. Deposit liquidity:");
        console.log("   Call deposit() on the manager at:", manager);
        console.log("\n2. Set up positions:");
        console.log("   Call rebalance() with your desired strategy");
        console.log("\n3. Configure fees (if needed):");
        console.log("   Owner can call setFee() to adjust protocol fee");
        console.log("\n4. Monitor positions:");
        console.log("   Use SimpleLens to preview operations");
        console.log("========================================\n");
    }
}
