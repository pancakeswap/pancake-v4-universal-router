// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {PancakeSwapV2Test} from "./PancakeSwapV2.t.sol";

contract V2BnbCake is PancakeSwapV2Test {
    ERC20 constant CAKE = ERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);

    function token0() internal pure override returns (address) {
        return address(CAKE);
    }

    function token1() internal pure override returns (address) {
        return address(WETH9);
    }
}
