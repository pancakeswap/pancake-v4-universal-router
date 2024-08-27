// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {V4Router} from "../../src/V4Router.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockV4Router is V4Router, ReentrancyLock {
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;

    constructor(IVault _vault, ICLPoolManager _poolManager, IBinPoolManager _binPoolManager)
        V4Router(_vault, _poolManager, _binPoolManager)
    {}

    function executeActions(bytes calldata params) external payable isNotLocked {
        _executeActions(params);
    }

    function executeActionsAndSweepExcessETH(bytes calldata params) external payable isNotLocked {
        _executeActions(params);

        uint256 balance = address(this).balance;
        if (balance > 0) {
            msg.sender.safeTransferETH(balance);
        }
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(vault), amount);
        } else {
            ERC20(Currency.unwrap(token)).safeTransferFrom(payer, address(vault), amount);
        }
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    receive() external payable {}
}
