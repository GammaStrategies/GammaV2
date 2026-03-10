# CamelStrategy Deployment Guide

## Overview

CamelStrategy implements a **double-peaked (camel) liquidity distribution** that concentrates liquidity around two price points. This is ideal for:
- Assets with bimodal price behavior
- Providing liquidity at multiple support/resistance levels
- Market-making strategies with two concentration zones

## Deployment Options

### Option 1: Standalone Deployment (Recommended for Single Strategy)

Deploy only the CamelStrategy contract:

```bash
forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy \
  --rpc-url <YOUR_RPC_URL> \
  --broadcast \
  --verify
```

**Example for Unichain Sepolia:**
```bash
forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy \
  --rpc-url https://sepolia.unichain.org \
  --broadcast \
  --verify
```

### Option 2: Full Infrastructure Deployment (All Strategies)

Deploy CamelStrategy along with all other strategies, factory, and SimpleLens:

```bash
forge script script/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url <YOUR_RPC_URL> \
  --broadcast \
  --verify \
  --sig "run(address,address)" <OWNER_ADDRESS> <POOL_MANAGER_ADDRESS>
```

**Example for Unichain:**
```bash
forge script script/DeployInfrastructure.s.sol:DeployInfrastructure \
  --rpc-url https://sepolia.unichain.org \
  --broadcast \
  --verify \
  --sig "run(address,address)" 0xYourAddress 0x1F98400000000000000000000000000000000004
```

## Strategy Features

### Double-Peaked Distribution
- **Left Peak**: First concentration point (lower price range)
- **Right Peak**: Second concentration point (higher price range)
- **Valley**: Reduced liquidity between peaks
- **Carpet Ranges**: Optional full-range positions at edges

### Configuration Parameters

When creating a MultiPositionManager with CamelStrategy:

```solidity
IMultiPositionManager.Config memory config = IMultiPositionManager.Config({
    strategy: camelStrategyAddress,
    // ... other parameters
});
```

Key strategy-specific parameters:
- **ticksLeft/ticksRight**: Distance from center to each peak
- **numRanges**: Number of liquidity ranges (typically 5-10)
- **useCarpet**: Enable edge protection
- **useAssetWeights**: Use proportional or explicit token weights

## Gas Optimizations

CamelStrategy has been optimized with:
- ✅ `unchecked { ++i; }` for loop increments (~30-40 gas/iteration)
- ✅ FullMath.mulDiv for precision in weight calculations
- ✅ Removed zero initializations (3-6 gas per variable)
- ✅ `!= 0` comparisons instead of `> 0` (3 gas per check)

## Post-Deployment Usage

After deployment, use the strategy address when creating position managers:

```bash
# Using the factory to deploy a manager with CamelStrategy
cast send <FACTORY_ADDRESS> \
  "deployMultiPositionManager(bytes32,address,(address,...))" \
  <POOL_ID> \
  <CAMEL_STRATEGY_ADDRESS> \
  <CONFIG_TUPLE>
```

## Verification

After deployment, verify the contract on block explorers:

```bash
forge verify-contract \
  --chain-id <CHAIN_ID> \
  <DEPLOYED_ADDRESS> \
  src/strategies/CamelStrategy.sol:CamelStrategy
```

## Testing Locally

Test the deployment script without broadcasting:

```bash
forge script script/DeployCamelStrategy.s.sol:DeployCamelStrategy
```

## Environment Setup

Required environment variables:

```bash
# .env file
DEPLOYER_PRIVATE_KEY=0x...
RPC_URL=https://sepolia.unichain.org
ETHERSCAN_API_KEY=your_api_key  # For verification
```

## Notes

- CamelStrategy is a **library-style contract** - deploy once and reuse across multiple position managers
- The strategy is **stateless** - all configuration is stored in the MultiPositionManager
- Gas cost: ~2.5M gas for deployment
- No initialization required after deployment

## Support

For issues or questions:
- Review test cases in `test/strategies/`
- Check strategy documentation in the contract comments
- Refer to the main project documentation
