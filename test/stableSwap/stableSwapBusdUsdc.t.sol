// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {StableSwapTest} from "./StableSwap.t.sol";

/// @dev StableSwap against this pool: https://bscscan.com/address/0xc2f5b9a3d9138ab2b74d581fc11346219ebf43fe
///      find more pairs at https://pancakeswap.finance/info?type=stableSwap
contract StableSwapBusdUsdcTest is StableSwapTest {
    ERC20 constant USDC = ERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    ERC20 constant BUSDC = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    function token0() internal pure override returns (address) {
        return address(USDC);
    }

    function token1() internal pure override returns (address) {
        return address(BUSDC);
    }

    function flag() internal pure override returns (uint256[] memory pairFlag) {
        pairFlag = new uint256[](1);
        pairFlag[0] = 2; // 2 is the flag to indicate StableSwapTwoPool
    }
}
