# GammaV2

GammaV2 is a Foundry workspace for the Gamma MultiPositionManager system on Uniswap v4.

It includes the core manager contracts, supported strategies, periphery lenses, relayer flow, deployment scripts, and the associated test suite used to build and validate the stack.

## Repository Layout

- `src/MultiPositionManager/`: core contracts, libraries, periphery contracts, and strategies
- `script/`: deployment, initialization, maintenance, and verification scripts
- `test/`: contract tests, strategy tests, lens tests, and supporting test utilities
- `audits/`: third-party audit reports

## Getting Started

```sh
forge build --force
forge test --force
```

## Scripts

The `script/` directory contains operational scripts for:

- infrastructure deployment
- MultiPositionManager and factory deployment
- strategy deployment
- relayer configuration
- lens deployment
- post-deployment maintenance and verification

## Audit

- [Gamma MultiPositionManager Audit Report](./audits/Gamma_Gamma_MultiPositionManager_report.pdf)
