// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IVolatilityOracle} from "./IVolatilityOracle.sol";

interface IVolatilityDynamicFeeHook {
    function managedPools(PoolId poolId) external view returns (bool);
    function volatilityOracle() external view returns (IVolatilityOracle);
}
