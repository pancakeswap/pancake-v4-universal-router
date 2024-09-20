// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PancakeSwapV3Test} from "./PancakeSwapV3.t.sol";

/// @dev V3 swap against this pool: https://bscscan.com/address/0x133b3d95bad5405d14d53473671200e9342896bf
contract V3BnbCake is PancakeSwapV3Test {
    ERC20 constant CAKE = ERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);

    // token1-token2 at 0.25%
    // WETH9-BTCB: https://bscscan.com/address/0xfc75f4e78bf71ed5066db9ca771d4ccb7c1264e0
    ERC20 constant BTCB = ERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);

    function token0() internal pure override returns (address) {
        return address(CAKE);
    }

    function token1() internal pure override returns (address) {
        return address(WETH9);
    }

    function token2() internal pure override returns (address) {
        return address(BTCB);
    }

    function fee() internal pure override returns (uint24) {
        return 2500; // 0.25%
    }
}
