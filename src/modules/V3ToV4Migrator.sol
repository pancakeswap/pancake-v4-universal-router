// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {RouterImmutables} from "../base/RouterImmutables.sol";
import {IV3NonfungiblePositionManager} from
    "pancake-v4-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";

/// @title V3 to V4 Migrator
/// @notice A contract that migrates liquidity from PancakeSwap V3 to V4
abstract contract V3ToV4Migrator is RouterImmutables {
    /// @dev validate if an action is decreaseLiquidity, collect, or burn
    function isValidAction(bytes4 selector) internal pure returns (bool) {
        return selector == IV3NonfungiblePositionManager.decreaseLiquidity.selector
            || selector == IV3NonfungiblePositionManager.collect.selector
            || selector == IV3NonfungiblePositionManager.burn.selector;
    }

    /// @dev the caller is authorized for the token if its the owner, spender, or operator
    function isAuthorizedForToken(address caller, uint256 tokenId) internal view returns (bool) {
        address owner = V3_POSITION_MANAGER.ownerOf(tokenId);
        return caller == owner || V3_POSITION_MANAGER.getApproved(tokenId) == caller
            || V3_POSITION_MANAGER.isApprovedForAll(owner, caller);
    }
}
