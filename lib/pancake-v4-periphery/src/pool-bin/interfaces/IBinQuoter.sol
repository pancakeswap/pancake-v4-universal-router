// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {IQuoter} from "../../interfaces/IQuoter.sol";

/// @title IBinQuoter Interface
/// @notice Supports quoting the delta amounts from exact input or exact output swaps.
/// @notice For each pool also tells you the activeId of the pool after the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IBinQuoter is IQuoter {
    struct QuoteResult {
        int128[] deltaAmounts;
        uint24[] activeIdAfterList;
    }

    struct QuoteCache {
        BalanceDelta curDeltas;
        uint128 prevAmount;
        int128 deltaIn;
        int128 deltaOut;
        Currency prevCurrency;
        uint24 activeIdAfter;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    /// @notice Returns the delta amounts for a given exact input swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactInputSingleParams`
    /// poolKey The key for identifying a Bin pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired input amount
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return deltaAmounts Delta amounts resulted from the swap
    /// @return activeIdAfter The activeId of the pool after the swap
    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (int128[] memory deltaAmounts, uint24 activeIdAfter);

    /// @notice Returns the delta amounts along the swap path for a given exact input swap
    /// @param params the params for the quote, encoded as 'QuoteExactInputParams'
    /// currencyIn The input currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, and hook info
    /// exactAmount The desired input amount
    /// @return deltaAmounts Delta amounts along the path resulted from the swap
    /// @return activeIdAfterList The list for activeId of the pool after the swap
    function quoteExactInput(QuoteExactParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList);

    /// @notice Returns the delta amounts for a given exact output swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactOutputSingleParams`
    /// poolKey The key for identifying a Bin pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired output amount
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return deltaAmounts Delta amounts resulted from the swap
    /// @return activeIdAfter The activeId of the pool after the swap
    function quoteExactOutputSingle(QuoteExactSingleParams calldata params)
        external
        returns (int128[] memory deltaAmounts, uint24 activeIdAfter);

    /// @notice Returns the delta amounts along the swap path for a given exact output swap
    /// @param params the params for the quote, encoded as 'QuoteExactOutputParams'
    /// currencyOut The output currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, and hook info
    /// exactAmount The desired output amount
    /// @return deltaAmounts Delta amounts along the path resulted from the swap
    /// @return activeIdAfterList The list for activeId of the pool after the swap
    function quoteExactOutput(QuoteExactParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList);

    function _quoteExactInputSingle(QuoteExactSingleParams memory params) external returns (bytes memory);

    function _quoteExactOutputSingle(QuoteExactSingleParams memory params) external returns (bytes memory);
}
