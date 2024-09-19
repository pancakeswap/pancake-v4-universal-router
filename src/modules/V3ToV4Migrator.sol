// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {RouterImmutables} from "../base/RouterImmutables.sol";
import {IV3NonfungiblePositionManager} from
    "pancake-v4-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {CalldataDecoder} from "pancake-v4-periphery/src/libraries/CalldataDecoder.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IPositionManager} from "pancake-v4-periphery/src/interfaces/IPositionManager.sol";

/// @title V3 to V4 Migrator
/// @notice A contract that migrates liquidity from PancakeSwap V3 to V4
abstract contract V3ToV4Migrator is RouterImmutables {
    using CalldataDecoder for bytes;

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

    function containInValidV4AClActions(bytes calldata inputs) internal pure returns (bool isInvalid, uint256 action) {
        // Decode the data of modifyLiquidities(bytes calldata payload, uint256 deadline)
        bytes4 selector = bytes4(inputs[:4]); // todo:

        if (selector == IPositionManager.modifyLiquidities.selector) {
            bytes calldata data = inputs[4:];

            // decode payload to get bytes calldata actions, bytes[] calldata params
            (bytes memory payload,) = abi.decode(data, (bytes, uint256));
            (bytes memory actions,) = abi.decode(payload, (bytes, bytes[]));

            for (uint256 actionIndex = 0; actionIndex < actions.length; actionIndex++) {
                action = uint8(actions[actionIndex]);
                if (
                    action == Actions.CL_INCREASE_LIQUIDITY || action == Actions.CL_DECREASE_LIQUIDITY
                        || action == Actions.CL_BURN_POSITION
                ) {
                    return (true, action);
                }
            }
        } else if (selector == IPositionManager.modifyLiquiditiesWithoutLock.selector) {
            // todo:
        } else if (selector == Multicall.multicall.selector) {
            // todo:
        }

        // todo: revert InvalidSelector
    }
}
