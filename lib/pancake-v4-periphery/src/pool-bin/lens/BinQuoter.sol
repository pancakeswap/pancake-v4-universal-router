// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {IBinQuoter} from "../interfaces/IBinQuoter.sol";
import {PathKey, PathKeyLib} from "../../libraries/PathKey.sol";
import {Quoter} from "../../base/Quoter.sol";

contract BinQuoter is Quoter, IBinQuoter {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint128;
    using PathKeyLib for PathKey;

    IBinPoolManager public immutable poolManager;

    /// @dev min valid reason is 2-words long
    /// @dev int128[2] + activeIdAfter padded to 32bytes
    /// MINIMUM_VALID_RESPONSE_LENGTH = 64;
    constructor(address _poolManager) Quoter(_poolManager, 64) {
        poolManager = IBinPoolManager(_poolManager);
    }

    /// @inheritdoc IBinQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint24 activeIdAfter)
    {
        try vault.lock(abi.encodeWithSelector(this._quoteExactInputSingle.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList)
    {
        try vault.lock(abi.encodeWithSelector(this._quoteExactInput.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint24 activeIdAfter)
    {
        try vault.lock(abi.encodeWithSelector(this._quoteExactOutputSingle.selector, params)) {}
        catch (bytes memory reason) {
            delete amountOutCached;
            return _handleRevertSingle(reason);
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        override
        returns (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList)
    {
        try vault.lock(abi.encodeWithSelector(this._quoteExactOutput.selector, params)) {}
        catch (bytes memory reason) {
            return _handleRevert(reason);
        }
    }

    /// @dev parse revert bytes from a single-pool quote
    function _handleRevertSingle(bytes memory reason)
        private
        view
        returns (int128[] memory deltaAmounts, uint24 activeIdAfter)
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, activeIdAfter) = abi.decode(reason, (int128[], uint24));
    }

    /// @dev parse revert bytes from a potentially multi-hop quote and return the delta amounts, activeIdAfter
    function _handleRevert(bytes memory reason)
        private
        view
        returns (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList)
    {
        reason = validateRevertReason(reason);
        (deltaAmounts, activeIdAfterList) = abi.decode(reason, (int128[], uint24[]));
    }

    /// @dev quote an ExactInput swap along a path of tokens, then revert with the result
    function _quoteExactInput(QuoteExactParams memory params) public override selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result =
            QuoteResult({deltaAmounts: new int128[](pathLength + 1), activeIdAfterList: new uint24[](pathLength)});
        QuoteCache memory cache;

        for (uint256 i = 0; i < pathLength; i++) {
            (PoolKey memory poolKey, bool zeroForOne) =
                params.path[i].getPoolAndSwapDirection(i == 0 ? params.exactCurrency : cache.prevCurrency);

            (cache.curDeltas, cache.activeIdAfter) = _swap(
                poolKey, zeroForOne, -int128(i == 0 ? params.exactAmount : cache.prevAmount), params.path[i].hookData
            );

            (cache.deltaIn, cache.deltaOut) = zeroForOne
                ? (cache.curDeltas.amount0(), cache.curDeltas.amount1())
                : (cache.curDeltas.amount1(), cache.curDeltas.amount0());
            result.deltaAmounts[i] += cache.deltaIn;
            result.deltaAmounts[i + 1] += cache.deltaOut;
            result.activeIdAfterList[i] = cache.activeIdAfter;

            cache.prevAmount = zeroForOne ? uint128(cache.curDeltas.amount1()) : uint128(cache.curDeltas.amount0());
            cache.prevCurrency = params.path[i].intermediateCurrency;
        }
        bytes memory r = abi.encode(result.deltaAmounts, result.activeIdAfterList);
        assembly ("memory-safe") {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams memory params)
        public
        override
        selfOnly
        returns (bytes memory)
    {
        (BalanceDelta deltas, uint24 activeIdAfter) =
            _swap(params.poolKey, params.zeroForOne, -(params.exactAmount.safeInt128()), params.hookData);

        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        bytes memory result = abi.encode(deltaAmounts, activeIdAfter);

        assembly ("memory-safe") {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams memory params) public override selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;

        QuoteResult memory result =
            QuoteResult({deltaAmounts: new int128[](pathLength + 1), activeIdAfterList: new uint24[](pathLength)});
        QuoteCache memory cache;
        uint128 curAmountOut;

        for (uint256 i = pathLength; i > 0; i--) {
            curAmountOut = i == pathLength ? params.exactAmount : cache.prevAmount;
            amountOutCached = curAmountOut;

            (PoolKey memory poolKey, bool oneForZero) = PathKeyLib.getPoolAndSwapDirection(
                params.path[i - 1], i == pathLength ? params.exactCurrency : cache.prevCurrency
            );

            (cache.curDeltas, cache.activeIdAfter) =
                _swap(poolKey, !oneForZero, int128(curAmountOut), params.path[i - 1].hookData);

            delete amountOutCached;
            (cache.deltaIn, cache.deltaOut) = !oneForZero
                ? (cache.curDeltas.amount0(), cache.curDeltas.amount1())
                : (cache.curDeltas.amount1(), cache.curDeltas.amount0());
            result.deltaAmounts[i - 1] += cache.deltaIn;
            result.deltaAmounts[i] += cache.deltaOut;
            result.activeIdAfterList[i - 1] = cache.activeIdAfter;

            cache.prevAmount = !oneForZero ? uint128(-cache.curDeltas.amount0()) : uint128(-cache.curDeltas.amount1());
            cache.prevCurrency = params.path[i - 1].intermediateCurrency;
        }
        bytes memory r = abi.encode(result.deltaAmounts, result.activeIdAfterList);
        assembly ("memory-safe") {
            revert(add(0x20, r), mload(r))
        }
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams memory params)
        public
        override
        selfOnly
        returns (bytes memory)
    {
        amountOutCached = params.exactAmount;

        (BalanceDelta deltas, uint24 activeIdAfter) =
            _swap(params.poolKey, params.zeroForOne, params.exactAmount.safeInt128(), params.hookData);

        if (amountOutCached != 0) delete amountOutCached;
        int128[] memory deltaAmounts = new int128[](2);

        deltaAmounts[0] = deltas.amount0();
        deltaAmounts[1] = deltas.amount1();

        bytes memory result = abi.encode(deltaAmounts, activeIdAfter);
        assembly ("memory-safe") {
            revert(add(0x20, result), mload(result))
        }
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
    /// @notice if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
    function _swap(PoolKey memory poolKey, bool zeroForOne, int128 amountSpecified, bytes memory hookData)
        private
        returns (BalanceDelta deltas, uint24 activeIdAfter)
    {
        deltas = poolManager.swap(poolKey, zeroForOne, amountSpecified, hookData);

        // only exactOut case
        if (amountOutCached != 0 && amountOutCached != uint128(zeroForOne ? deltas.amount1() : deltas.amount0())) {
            revert InsufficientAmountOut();
        }

        (activeIdAfter,,) = poolManager.getSlot0(poolKey.toId());
    }
}
