// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ImmutableState} from "./ImmutableState.sol";

abstract contract SafeCallback is ImmutableState, ILockCallback {
    error NotVault();

    constructor(IVault _vault) ImmutableState(_vault) {}

    modifier onlyByVault() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    /// @dev We force the onlyByVault modifier by exposing a virtual function after the onlyByVault check.
    function lockAcquired(bytes calldata data) external onlyByVault returns (bytes memory) {
        return _lockAcquired(data);
    }

    function _lockAcquired(bytes calldata data) internal virtual returns (bytes memory);
}
