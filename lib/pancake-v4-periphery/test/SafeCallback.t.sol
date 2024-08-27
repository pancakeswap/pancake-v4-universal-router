//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IVault, Vault} from "pancake-v4-core/src/Vault.sol";

import {SafeCallback} from "../src/base/SafeCallback.sol";
import {MockSafeCallback} from "./mocks/MockSafeCallback.sol";

contract SafeCallbackTest is Test {
    MockSafeCallback safeCallback;

    IVault vault;

    function setUp() public {
        vault = new Vault();
        safeCallback = new MockSafeCallback(vault);
    }

    function test_vaultAddress() public view {
        assertEq(address(safeCallback.vault()), address(vault));
    }

    function test_lock(uint256 num) public {
        bytes memory result = safeCallback.lock(num);
        assertEq(num, abi.decode(result, (uint256)));
    }

    function test_lockRevert(address caller, bytes calldata data) public {
        vm.startPrank(caller);
        if (caller != address(vault)) vm.expectRevert(SafeCallback.NotVault.selector);
        safeCallback.lockAcquired(data);
        vm.stopPrank();
    }
}
