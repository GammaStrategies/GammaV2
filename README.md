# GammaV2

GammaV2 is a reduced Foundry workspace that keeps only the MultiPositionManager stack from the original repository.

Included:
- `src/MultiPositionManager` contracts, strategies, lenses, routers, and relayer/factory flow
- MPM-only deployment and maintenance scripts in `script/`
- Local MPM-focused test coverage in `test/`

Excluded:
- `src/LaunchPad`
- `src/LimitOrderBook`
- `src/Periphery`
- `src/Unilaunch`
- `src/MultiPositionManager/periphery/RelayerLens.sol`
- `src/MultiPositionManager/interfaces/IRelayerLens.sol`
- Fork, integration, and non-MPM tests

## Commands

```sh
forge build --force
forge test --force
```
