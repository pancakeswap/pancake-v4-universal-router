// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";

// A PositionConfig is the input for creating and modifying a Position in core, whose truncated hash is set per tokenId
struct PositionConfig {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Library to calculate the PositionConfigId from the PositionConfig struct
library PositionConfigLibrary {
    function toId(PositionConfig calldata config) internal pure returns (bytes32 id) {
        // id = keccak256(abi.encodePacked(currency0, currency1, hooks, poolManager, fee, parameters, tickLower, tickUpper))) >> 1
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x65), calldataload(add(config, 0xe0))) // tickUpper: [0x82, 0x85)
            mstore(add(fmp, 0x62), calldataload(add(config, 0xc0))) // tickLower: [0x7f, 0x82)
            mstore(add(fmp, 0x5f), calldataload(add(config, 0xa0))) // parameters: [0x5f, 0x7f)
            mstore(add(fmp, 0x3f), calldataload(add(config, 0x80))) // fee: [0x5c, 0x5f)
            mstore(add(fmp, 0x3c), calldataload(add(config, 0x60))) // poolManager: [0x48, 0x5c)
            mstore(add(fmp, 0x28), calldataload(add(config, 0x40))) // hooks: [0x34, 0x48)
            mstore(add(fmp, 0x14), calldataload(add(config, 0x20))) // currency1: [0x20, 0x34)
            mstore(fmp, calldataload(config)) // currency0: [0x0c, 0x20)

            id := shr(1, keccak256(add(fmp, 0x0c), 0x79)) // len is 121 bytes, truncate lower bit of the hash

            // now clean the memory we used
            mstore(add(fmp, 0x80), 0) // fmp+0x80 held tickUpper(2 bytes), tickLower
            mstore(add(fmp, 0x60), 0) // fmp+0x60 held parameters(31 bytes), tickUpper(1 bytes)
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held hooks (8 bytes), poolManager, fee, parameters (1 bytes)
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held currency1, hooks(12 bytes)
            mstore(fmp, 0) // fmp held currency0
        }
    }
}
