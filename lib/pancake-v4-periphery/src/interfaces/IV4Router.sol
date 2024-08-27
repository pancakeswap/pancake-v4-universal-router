// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {ICLRouterBase} from "../pool-cl/interfaces/ICLRouterBase.sol";
import {IBinRouterBase} from "../pool-bin/interfaces/IBinRouterBase.sol";

/// @title IV4Router
/// @notice Interface containing all the structs and errors for different v4 swap types
interface IV4Router is ICLRouterBase, IBinRouterBase {
    /// @notice Emitted when an exactInput swap does not receive its minAmountOut
    error V4TooLittleReceived();
    /// @notice Emitted when an exactOutput is asked for more than its maxAmountIn
    error V4TooMuchRequested();
}
