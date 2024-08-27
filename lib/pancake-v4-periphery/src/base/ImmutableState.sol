// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";

contract ImmutableState {
    IVault public immutable vault;

    constructor(IVault _vault) {
        vault = _vault;
    }
}
