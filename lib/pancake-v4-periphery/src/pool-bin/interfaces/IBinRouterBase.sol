// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.20;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PathKey} from "../../libraries/PathKey.sol";

interface IBinRouterBase {
    struct BinSwapExactInputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct BinSwapExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct BinSwapExactOutputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct BinSwapExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
}
