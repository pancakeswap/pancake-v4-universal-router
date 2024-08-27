// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";

/// @notice Library for computing the token of binId in a pool
library BinTokenLibrary {
    function toTokenId(PoolId poolId, uint256 binId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, binId)));
    }
}
