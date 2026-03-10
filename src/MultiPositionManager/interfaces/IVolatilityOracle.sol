// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IVolatilityOracle {
    function consult(PoolKey memory key, uint32 secondsAgo) external view returns (int24, uint128);
}
