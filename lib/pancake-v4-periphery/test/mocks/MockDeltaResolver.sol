// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockDeltaResolver is Test, DeltaResolver, ILockCallback {
    using CurrencyLibrary for Currency;

    uint256 public payCallCount;

    constructor(IVault _vault) ImmutableState(_vault) {}

    function executeTest(Currency currency, uint256 amount) external {
        vault.lock(abi.encode(currency, msg.sender, amount));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (Currency currency, address caller, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        address recipient = (currency.isNative()) ? address(this) : caller;

        uint256 balanceBefore = currency.balanceOf(recipient);
        _take(currency, recipient, amount);
        uint256 balanceAfter = currency.balanceOf(recipient);

        assertEq(balanceBefore + amount, balanceAfter);

        balanceBefore = balanceAfter;
        _settle(currency, recipient, amount);
        balanceAfter = currency.balanceOf(recipient);

        assertEq(balanceBefore - amount, balanceAfter);

        return "";
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        ERC20(Currency.unwrap(token)).transferFrom(payer, address(vault), amount);
        payCallCount++;
    }

    // needs to receive native tokens from the `take` call
    receive() external payable {}
}
