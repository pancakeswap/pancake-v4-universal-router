// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IQuoter} from "../interfaces/IQuoter.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";

abstract contract Quoter is IQuoter, ILockCallback {
    /// @dev cache used to check a safety condition in exact output swaps.
    uint128 internal amountOutCached;

    IVault public immutable vault;

    /// @dev min valid reason is n-words long
    uint256 internal immutable MINIMUM_VALID_RESPONSE_LENGTH;

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address _poolManager, uint256 _minLength) {
        vault = IPoolManager(_poolManager).vault();
        MINIMUM_VALID_RESPONSE_LENGTH = _minLength;
    }

    /// @inheritdoc ILockCallback
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) {
            revert InvalidLockAcquiredSender();
        }

        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    /// @dev check revert bytes and pass through if considered valid; otherwise revert with different message
    function validateRevertReason(bytes memory reason) internal view returns (bytes memory) {
        if (reason.length < MINIMUM_VALID_RESPONSE_LENGTH) {
            revert UnexpectedRevertBytes(reason);
        }
        return reason;
    }
}
