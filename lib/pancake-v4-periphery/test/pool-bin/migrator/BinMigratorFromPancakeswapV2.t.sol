// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BinMigratorFromV2} from "./BinMigratorFromV2.sol";

contract BinMigratorFromPancakeswapV2Test is BinMigratorFromV2 {
    function _getBytecodePath() internal pure override returns (string memory) {
        // Create a Pancakeswap V2 pair
        // relative to the root of the project
        // https://etherscan.io/address/0x1097053Fd2ea711dad45caCcc45EfF7548fCB362#code
        return "./test/bin/pcsV2Factory.bytecode";
    }

    function _getContractName() internal pure override returns (string memory) {
        return "BinMigratorFromPancakeswapV2Test";
    }
}
