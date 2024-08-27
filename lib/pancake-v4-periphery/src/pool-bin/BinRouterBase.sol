// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.20;

import {CurrencyLibrary, Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinRouterBase} from "./interfaces/IBinRouterBase.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {PathKeyLib, PathKey} from "../libraries/PathKey.sol";
import {SafeCastTemp} from "../libraries/SafeCast.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

abstract contract BinRouterBase is IBinRouterBase, DeltaResolver {
    using CurrencyLibrary for Currency;
    using PathKeyLib for PathKey;
    using SafeCastTemp for *;
    using SafeCast for *;

    IBinPoolManager public immutable binPoolManager;

    constructor(IBinPoolManager _binPoolManager) {
        binPoolManager = _binPoolManager;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _swapExactInputSingle(BinSwapExactInputSingleParams calldata params) internal {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn = _getFullCredit(params.swapForY ? params.poolKey.currency0 : params.poolKey.currency1).safe128();
        }
        uint128 amountOut =
            _swapExactPrivate(params.poolKey, params.swapForY, -(amountIn.safeInt128()), params.hookData).toUint128();

        if (amountOut < params.amountOutMinimum) revert IV4Router.V4TooLittleReceived();
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _swapExactInput(BinSwapExactInputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).safe128();
            PathKey calldata pathKey;

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool swapForY) = pathKey.getPoolAndSwapDirection(currencyIn);

                amountOut = _swapExactPrivate(poolKey, swapForY, -(amountIn.safeInt128()), pathKey.hookData).toUint128();

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert IV4Router.V4TooLittleReceived();
        }
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _swapExactOutputSingle(BinSwapExactOutputSingleParams calldata params) internal {
        uint128 amountIn = (
            -_swapExactPrivate(params.poolKey, params.swapForY, params.amountOut.safeInt128(), params.hookData)
        ).toUint128();

        if (amountIn > params.amountInMaximum) revert IV4Router.V4TooMuchRequested();
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _swapExactOutput(BinSwapExactOutputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            /// @dev Iterate backward from last path to first path
            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                // find out poolKey and how much amountIn required to get amountOut
                (PoolKey memory poolKey, bool swapForY) = pathKey.getPoolAndSwapDirection(currencyOut);

                amountIn =
                    (-_swapExactPrivate(poolKey, !swapForY, amountOut.safeInt128(), pathKey.hookData)).toUint128();

                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }

            if (amountIn > params.amountInMaximum) revert IV4Router.V4TooMuchRequested();
        }
    }

    /// @return reciprocalAmount The amount of the reciprocal token
    //      If exactInput token0 for token1, the reciprocalAmount is the amount of token1.
    //      If exactOutput token0 for token1, the reciprocalAmount is the amount of token0.
    function _swapExactPrivate(PoolKey memory poolKey, bool swapForY, int128 amountSpecified, bytes calldata hookData)
        private
        returns (int128 reciprocalAmount)
    {
        BalanceDelta delta = binPoolManager.swap(poolKey, swapForY, amountSpecified, hookData);
        reciprocalAmount = (swapForY == amountSpecified < 0) ? delta.amount1() : delta.amount0();
    }
}
