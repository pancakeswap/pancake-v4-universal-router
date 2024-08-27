// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";

import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";

contract CalldataDecoderTest is Test {
    MockCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    function test_fuzz_decodeCurrencyAndAddress(Currency _currency, address __address) public view {
        bytes memory params = abi.encode(_currency, __address);
        (Currency currency, address _address) = decoder.decodeCurrencyAndAddress(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrency(Currency _currency) public view {
        bytes memory params = abi.encode(_currency);
        (Currency currency) = decoder.decodeCurrency(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
    }

    function test_fuzz_decodeCurrencyPair(Currency _currency0, Currency _currency1) public view {
        bytes memory params = abi.encode(_currency0, _currency1);
        (Currency currency0, Currency currency1) = decoder.decodeCurrencyPair(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
    }

    function test_fuzz_decodeCurrencyPairAndAddress(Currency _currency0, Currency _currency1, address __address)
        public
        view
    {
        bytes memory params = abi.encode(_currency0, _currency1, __address);
        (Currency currency0, Currency currency1, address _address) = decoder.decodeCurrencyPairAndAddress(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrencyAddressAndUint256(Currency _currency, address _addr, uint256 _amount)
        public
        view
    {
        bytes memory params = abi.encode(_currency, _addr, _amount);
        (Currency currency, address addr, uint256 amount) = decoder.decodeCurrencyAddressAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(addr, _addr);
        assertEq(amount, _amount);
    }

    function test_fuzz_decodeCurrencyAndUint256(Currency _currency, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _amount);
        (Currency currency, uint256 amount) = decoder.decodeCurrencyAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
    }
}
