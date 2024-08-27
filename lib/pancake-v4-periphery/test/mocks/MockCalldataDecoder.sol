// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

// we need to use a mock contract to make the calls happen in calldata not memory
contract MockCalldataDecoder {
    using CalldataDecoder for bytes;

    function decodeCurrencyAndAddress(bytes calldata params)
        external
        pure
        returns (Currency currency, address _address)
    {
        return params.decodeCurrencyAndAddress();
    }

    function decodeCurrency(bytes calldata params) external pure returns (Currency currency) {
        return params.decodeCurrency();
    }

    function decodeCurrencyPair(bytes calldata params) external pure returns (Currency currency0, Currency currency1) {
        return params.decodeCurrencyPair();
    }

    function decodeCurrencyPairAndAddress(bytes calldata params)
        external
        pure
        returns (Currency currency0, Currency currency1, address _address)
    {
        return params.decodeCurrencyPairAndAddress();
    }

    function decodeCurrencyAndUint256(bytes calldata params) external pure returns (Currency currency, uint256 _uint) {
        return params.decodeCurrencyAndUint256();
    }

    function decodeCurrencyAddressAndUint256(bytes calldata params)
        external
        pure
        returns (Currency currency, address addr, uint256 amount)
    {
        return params.decodeCurrencyAddressAndUint256();
    }
}
