// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IBinPositionManager} from "../interfaces/IBinPositionManager.sol";
import {IV4Router} from "../../interfaces/IV4Router.sol";

/// @title Library for abi decoding in bin pool calldata
library BinCalldataDecoder {
    /// todo: <wip> see if tweaking to calldataload saves gas
    /// @dev equivalent to: abi.decode(params, (IBinPositionManager.BinAddLiquidityParams))
    function decodeBinAddLiquidityParams(bytes calldata params)
        internal
        pure
        returns (IBinPositionManager.BinAddLiquidityParams calldata addLiquidityParams)
    {
        assembly {
            addLiquidityParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// todo: <wip> see if tweaking to calldataload saves gas
    /// @dev equivalent to: abi.decode(params, (IBinPositionManager.BinRemoveLiquidityParams))
    function decodeBinRemoveLiquidityParams(bytes calldata params)
        internal
        pure
        returns (IBinPositionManager.BinRemoveLiquidityParams calldata removeLiquidityParams)
    {
        assembly {
            removeLiquidityParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.BinExactInputParams))
    function decodeBinSwapExactInParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.BinSwapExactInputParams calldata swapParams)
    {
        // BinExactInputParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.BinExactInputSingleParams))
    function decodeBinSwapExactInSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.BinSwapExactInputSingleParams calldata swapParams)
    {
        // BinExactInputSingleParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.BinExactOutputParams))
    function decodeBinSwapExactOutParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.BinSwapExactOutputParams calldata swapParams)
    {
        // BinExactOutputParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to: abi.decode(params, (IV4Router.BinExactOutputSingleParams))
    function decodeBinSwapExactOutSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.BinSwapExactOutputSingleParams calldata swapParams)
    {
        // BinExactOutputSingleParams is a variable length struct so we just have to look up its location
        assembly ("memory-safe") {
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }
}
