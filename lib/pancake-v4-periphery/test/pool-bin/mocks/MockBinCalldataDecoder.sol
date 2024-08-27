// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BinCalldataDecoder} from "../../../src/pool-bin/libraries/BinCalldataDecoder.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
import {IBinPositionManager} from "../../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

// we need to use a mock contract to make the calls happen in calldata not memory
contract MockBinCalldataDecoder {
    using BinCalldataDecoder for bytes;

    function decodeBinAddLiquidityParams(bytes calldata params)
        external
        pure
        returns (IBinPositionManager.BinAddLiquidityParams calldata addLiquidityParams)
    {
        return params.decodeBinAddLiquidityParams();
    }

    function decodeBinRemoveLiquidityParams(bytes calldata params)
        external
        pure
        returns (IBinPositionManager.BinRemoveLiquidityParams calldata removeLiquidityParams)
    {
        return params.decodeBinRemoveLiquidityParams();
    }

    function decodeBinSwapExactInParams(bytes calldata params)
        external
        pure
        returns (IV4Router.BinSwapExactInputParams calldata swapParams)
    {
        return params.decodeBinSwapExactInParams();
    }

    function decodeBinSwapExactInSingleParams(bytes calldata params)
        external
        pure
        returns (IV4Router.BinSwapExactInputSingleParams calldata swapParams)
    {
        return params.decodeBinSwapExactInSingleParams();
    }

    function decodeBinSwapExactOutParams(bytes calldata params)
        external
        pure
        returns (IV4Router.BinSwapExactOutputParams calldata swapParams)
    {
        return params.decodeBinSwapExactOutParams();
    }

    function decodeBinSwapExactOutSingleParams(bytes calldata params)
        external
        pure
        returns (IV4Router.BinSwapExactOutputSingleParams calldata swapParams)
    {
        return params.decodeBinSwapExactOutSingleParams();
    }
}
