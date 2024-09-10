// SPDX-License-Identifier: GPL-3.0-or-later

/// @title Library for Bytes Manipulation
pragma solidity ^0.8.0;

import {Constants} from "./Constants.sol";
import {CalldataDecoder} from "pancake-v4-periphery/src/libraries/CalldataDecoder.sol";

library BytesLib {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice Returns the address starting at byte 0
    /// @dev length and overflow checks must be carried out before calling
    /// @param _bytes The input bytes string to slice
    /// @return _address The address starting at byte 0
    function toAddress(bytes calldata _bytes) internal pure returns (address _address) {
        if (_bytes.length < Constants.ADDR_SIZE) revert SliceOutOfBounds();
        assembly {
            _address := shr(96, calldataload(_bytes.offset))
        }
    }

    /// @notice Returns the pool details starting at byte 0
    /// @dev length and overflow checks must be carried out before calling
    /// @param _bytes The input bytes string to slice
    /// @return token0 The address at byte 0
    /// @return fee The uint24 starting at byte 20
    /// @return token1 The address at byte 23
    function toPool(bytes calldata _bytes) internal pure returns (address token0, uint24 fee, address token1) {
        if (_bytes.length < Constants.V3_POP_OFFSET) revert SliceOutOfBounds();
        assembly {
            let firstWord := calldataload(_bytes.offset)
            token0 := shr(96, firstWord)
            fee := and(shr(72, firstWord), 0xffffff)
            token1 := shr(96, calldataload(add(_bytes.offset, 23)))
        }
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as `address[]`
    /// @param _bytes The input bytes string to extract an address array from
    /// @param _arg The index of the argument to extract
    function toAddressArray(bytes calldata _bytes, uint256 _arg) internal pure returns (address[] calldata res) {
        (uint256 length, uint256 offset) = _bytes.toLengthOffset(_arg);
        assembly {
            res.length := length
            res.offset := offset
        }
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as `uint[]`
    /// @param _bytes The input bytes string to extract an uint array from
    /// @param _arg The index of the argument to extract
    function toUintArray(bytes calldata _bytes, uint256 _arg) internal pure returns (uint256[] calldata res) {
        (uint256 length, uint256 offset) = _bytes.toLengthOffset(_arg);
        assembly {
            res.length := length
            res.offset := offset
        }
    }

    /// @notice Equivalent to abi.decode(bytes, bytes[])
    /// @param _bytes The input bytes string to extract an parameters from
    function decodeCommandsAndInputs(bytes calldata _bytes) internal pure returns (bytes calldata, bytes[] calldata) {
        return _bytes.decodeActionsRouterParams();
    }
}
