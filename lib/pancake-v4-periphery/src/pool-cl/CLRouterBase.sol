// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.20;

import {CurrencyLibrary, Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {ICLRouterBase} from "./interfaces/ICLRouterBase.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {PathKeyLib, PathKey} from "../libraries/PathKey.sol";
import {SafeCastTemp} from "../libraries/SafeCast.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

abstract contract CLRouterBase is ICLRouterBase, DeltaResolver {
    using CurrencyLibrary for Currency;
    using PathKeyLib for PathKey;
    using SafeCastTemp for *;

    ICLPoolManager public immutable clPoolManager;

    constructor(ICLPoolManager _clPoolManager) {
        clPoolManager = _clPoolManager;
    }

    function _swapExactInputSingle(CLSwapExactInputSingleParams calldata params) internal {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut = _swapExactPrivate(
            params.poolKey, params.zeroForOne, int256(-int128(amountIn)), params.sqrtPriceLimitX96, params.hookData
        ).toUint128();
        if (amountOut < params.amountOutMinimum) revert IV4Router.V4TooLittleReceived();
    }

    function _swapExactInput(CLSwapExactInputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // The output delta will always be positive, except for when interacting with certain hook pools
                amountOut =
                    _swapExactPrivate(poolKey, zeroForOne, -int256(uint256(amountIn)), 0, pathKey.hookData).toUint128();

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert IV4Router.V4TooLittleReceived();
        }
    }

    function _swapExactOutputSingle(CLSwapExactOutputSingleParams calldata params) internal {
        uint128 amountIn = (
            -_swapExactPrivate(
                params.poolKey,
                params.zeroForOne,
                int256(int128(params.amountOut)),
                params.sqrtPriceLimitX96,
                params.hookData
            )
        ).toUint128();
        if (amountIn > params.amountInMaximum) revert IV4Router.V4TooMuchRequested();
    }

    function _swapExactOutput(CLSwapExactOutputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // The output delta will always be negative, except for when interacting with certain hook pools
                amountIn = (-_swapExactPrivate(poolKey, !oneForZero, int256(uint256(amountOut)), 0, pathKey.hookData))
                    .toUint128();

                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert IV4Router.V4TooMuchRequested();
        }
    }

    /// @return reciprocalAmount The amount of the reciprocal token
    //      If exactInput token0 for token1, the reciprocalAmount is the amount of token1.
    //      If exactOutput token0 for token1, the reciprocalAmount is the amount of token0.
    function _swapExactPrivate(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) private returns (int128 reciprocalAmount) {
        BalanceDelta delta = clPoolManager.swap(
            poolKey,
            ICLPoolManager.SwapParams(
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96
            ),
            hookData
        );

        reciprocalAmount = (zeroForOne == amountSpecified < 0) ? delta.amount1() : delta.amount0();
    }
}
