// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {Permit2Payments} from "../../Permit2Payments.sol";
import {V4Router} from "infinity-periphery/src/V4Router.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @title Router for PCS v4 Trades
abstract contract V4SwapRouter is V4Router, Permit2Payments {
    constructor(address _vault, address _clPoolManager, address _binPoolManager)
        V4Router(IVault(_vault), ICLPoolManager(_clPoolManager), IBinPoolManager(_binPoolManager))
    {}

    function _pay(Currency token, address payer, uint256 amount) internal override {
        payOrPermit2Transfer(Currency.unwrap(token), payer, address(vault), amount);
    }
}
