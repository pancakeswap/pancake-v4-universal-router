// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBaseMigrator} from "../../interfaces/IBaseMigrator.sol";
import {IV3NonfungiblePositionManager} from "../../interfaces/external/IV3NonfungiblePositionManager.sol";

interface IBinMigrator is IBaseMigrator {
    /// @notice same fields as IBinRouterBase.BinAddLiquidityParams
    /// except amount0/amount1 which will be calculated by migrator
    struct V4BinPoolParams {
        PoolKey poolKey;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        uint256 deadline;
    }

    /// @notice Migrate liquidity from v2 to v4
    /// @param v2PoolParams ncessary info for removing liqudity the source v2 pool
    /// @param v4PoolParams necessary info for adding liquidity the target v4 bin-pool
    /// @param extraAmount0 the extra amount of token0 that user wants to add (optional, usually 0)
    /// if pool token0 is ETH and msg.value == 0, WETH will be taken from sender.
    /// Otherwise if pool token0 is ETH and msg.value !=0, method will assume user have sent extraAmount0 in msg.value
    /// @param extraAmount1 the extra amount of token1 that user wants to add (optional, usually 0)
    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        V4BinPoolParams calldata v4PoolParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    /// @notice Migrate liquidity from v3 to v4
    /// @param v3PoolParams ncessary info for removing liqudity the source v3 pool
    /// @param v4PoolParams necessary info for adding liquidity the target v4 bin-pool
    /// @param extraAmount0 the extra amount of token0 that user wants to add (optional, usually 0)
    /// if pool token0 is ETH and msg.value == 0, WETH will be taken from sender.
    /// Otherwise if pool token0 is ETH and msg.value !=0, method will assume user have sent extraAmount0 in msg.value
    /// @param extraAmount1 the extra amount of token1 that user wants to add (optional, usually 0)
    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        V4BinPoolParams calldata v4PoolParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    /// @notice Initialize a pool for a given pool key, the function will forwards the call to the BinPoolManager
    /// @dev Call this when the pool does not exist and is not initialized
    /// @param poolKey The pool key
    /// @param activeId The active id of the pool
    /// @param hookData Hook data for the pool
    function initializePool(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external payable;
}
