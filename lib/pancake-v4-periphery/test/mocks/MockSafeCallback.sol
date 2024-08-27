// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IVault} from "pancake-v4-core/src/Vault.sol";

import "../../src/base/SafeCallback.sol";

contract MockSafeCallback is SafeCallback {
    constructor(IVault _vault) SafeCallback(_vault) {}

    function lock(uint256 num) external returns (bytes memory) {
        return vault.lock(abi.encode(num));
    }

    function _lockAcquired(bytes calldata data) internal pure override returns (bytes memory) {
        return data;
    }
}
