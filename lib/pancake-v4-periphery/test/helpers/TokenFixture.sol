// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract TokenFixture {
    Currency internal currency0;
    Currency internal currency1;
    Currency internal currency2;

    function initializeTokens() internal {
        MockERC20 token0 = new MockERC20("token0", "token0", 18);
        MockERC20 token1 = new MockERC20("token1", "token1", 18);
        MockERC20 token2 = new MockERC20("token2", "token2", 18);

        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token2.mint(address(this), 100 ether);

        (currency0, currency1, currency2) = sort(token0, token1, token2);
    }

    function sort(MockERC20 token0, MockERC20 token1, MockERC20 token2)
        private
        pure
        returns (Currency _currency0, Currency _currency1, Currency _currency2)
    {
        if (address(token0) > address(token1) && address(token0) > address(token2)) {
            _currency2 = Currency.wrap(address(token0));
            (_currency0, _currency1) = sort(token1, token2);
        } else if (address(token1) > address(token0) && address(token1) > address(token2)) {
            _currency2 = Currency.wrap(address(token1));
            (_currency0, _currency1) = sort(token0, token2);
        } else {
            _currency2 = Currency.wrap(address(token2));
            (_currency0, _currency1) = sort(token0, token1);
        }
    }

    function sort(MockERC20 token0, MockERC20 token1) private pure returns (Currency _currency0, Currency _currency1) {
        if (address(token0) < address(token1)) {
            (_currency0, _currency1) = (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            (_currency0, _currency1) = (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }
}
