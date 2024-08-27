// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {RouterImmutables} from "../base/RouterImmutables.sol";
import {IV3NonfungiblePositionManager} from
    "pancake-v4-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";

abstract contract V3ToV4Migrator is RouterImmutables {
    function isValidAction(bytes4 selector) internal pure returns (bool) {
        return selector == IV3NonfungiblePositionManager.decreaseLiquidity.selector
            || selector == IV3NonfungiblePositionManager.collect.selector
            || selector == IV3NonfungiblePositionManager.burn.selector;
    }

    function isAuthorizedForToken(address caller, uint256 tokenId) internal view returns (bool) {
        address owner = V3_POSITION_MANAGER.ownerOf(tokenId);
        return caller == owner || V3_POSITION_MANAGER.getApproved(tokenId) == caller
            || V3_POSITION_MANAGER.isApprovedForAll(owner, caller);
    }
}
