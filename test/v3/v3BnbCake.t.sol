// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PancakeSwapV3Test} from "./PancakeSwapV3.t.sol";

/// @dev V3 swap against this pool: https://bscscan.com/address/0x133b3d95bad5405d14d53473671200e9342896bf
contract V3BnbCake is PancakeSwapV3Test {
    ERC20 constant CAKE = ERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);

    function token0() internal pure override returns (address) {
        return address(CAKE);
    }

    function token1() internal pure override returns (address) {
        return address(WETH9);
    }

    function fee() internal pure override returns (uint24) {
        return 2500; // 0.25%
    }
}
