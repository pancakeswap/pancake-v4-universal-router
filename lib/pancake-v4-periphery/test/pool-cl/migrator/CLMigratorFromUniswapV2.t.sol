// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLMigratorFromV2} from "./CLMigratorFromV2.sol";

contract CLMigratorFromUniswapV2Test is CLMigratorFromV2 {
    function _getBytecodePath() internal pure override returns (string memory) {
        // Create a Uniswap V2 pair
        // relative to the root of the project
        // https://etherscan.io/address/0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f#code
        return "./test/bin/uniV2Factory.bytecode";
    }

    function _getContractName() internal pure override returns (string memory) {
        return "CLMigratorFromUniswapV2Test";
    }
}
