// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IMulticall_v4} from "./IMulticall_v4.sol";
import {ISelfPermitERC721} from "./ISelfPermitERC721.sol";

interface IBaseMigrator is IMulticall_v4, ISelfPermitERC721 {
    error TOKEN_NOT_MATCH();
    error INVALID_ETHER_SENDER();
    error INSUFFICIENT_AMOUNTS_RECEIVED();
    error NOT_TOKEN_OWNER();

    /// @notice The event emitted when extra funds are added to the migrator
    /// @param currency0 the address of the token0
    /// @param currency1 the address of the token1
    /// @param extraAmount0 the amount of extra token0
    /// @param extraAmount1 the amount of extra token1
    event ExtraFundsAdded(address currency0, address currency1, uint256 extraAmount0, uint256 extraAmount1);

    /// @notice Parameters for removing liquidity from v2
    struct V2PoolParams {
        // the PancakeSwap v2-compatible pair
        address pair;
        // the amount of v2 lp token to be withdrawn
        uint256 migrateAmount;
        // the amount of token0 and token1 to be received after burning must be no less than these
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /// @notice Parameters for removing liquidity from v3
    struct V3PoolParams {
        // the PancakeSwap v3-compatible NFP
        address nfp;
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        // decide whether to collect fee
        bool collectFee;
        uint256 deadline;
    }

    /// @notice refund native ETH to caller
    /// This is useful when the caller sends more ETH then he specifies in arguments
    function refundETH() external payable;
}
