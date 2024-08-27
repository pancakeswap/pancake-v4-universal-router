// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice A transient reentrancy lock, that stores the caller's address as the lock
contract ReentrancyLock {
    // The slot holding the locker state, transiently. bytes32(uint256(keccak256("LockedBy")) - 1)
    bytes32 constant LOCKED_BY_SLOT = 0x0aedd6bde10e3aa2adec092b02a3e3e805795516cda41f27aa145b8f300af87a;

    error ContractLocked();

    modifier isNotLocked() {
        if (_getLocker() != address(0)) revert ContractLocked();
        _setLocker(msg.sender);
        _;
        _setLocker(address(0));
    }

    function _setLocker(address locker) internal {
        assembly ("memory-safe") {
            tstore(LOCKED_BY_SLOT, locker)
        }
    }

    function _getLocker() internal view returns (address locker) {
        assembly ("memory-safe") {
            locker := tload(LOCKED_BY_SLOT)
        }
    }
}
