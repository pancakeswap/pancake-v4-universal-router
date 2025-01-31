// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {RouterImmutables} from "../base/RouterImmutables.sol";
import {IV3NonfungiblePositionManager} from
    "infinity-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "infinity-periphery/src/libraries/CalldataDecoder.sol";
import {IPositionManager} from "infinity-periphery/src/interfaces/IPositionManager.sol";
import {IERC721Permit} from "infinity-periphery/src/interfaces/IERC721Permit.sol";

/// @title V3 to Infinity Migrator
/// @notice A contract that migrates liquidity from PancakeSwap V3 to Infinity
abstract contract V3ToInfinityMigrator is RouterImmutables {
    using CalldataDecoder for bytes;

    error NotAuthorizedForToken(uint256 tokenId);
    error InvalidAction(bytes4 action);
    error OnlyMintAllowed();
    error OnlyAddLiqudityAllowed();

    /// @dev validate if an action is decreaseLiquidity, collect, or burn
    function _isValidAction(bytes4 selector) private pure returns (bool) {
        return selector == IV3NonfungiblePositionManager.decreaseLiquidity.selector
            || selector == IV3NonfungiblePositionManager.collect.selector
            || selector == IV3NonfungiblePositionManager.burn.selector;
    }

    /// @dev the caller is authorized for the token if its the owner, spender, or operator
    function _isAuthorizedForToken(address caller, uint256 tokenId) private view returns (bool) {
        address owner = V3_POSITION_MANAGER.ownerOf(tokenId);
        return caller == owner || V3_POSITION_MANAGER.getApproved(tokenId) == caller
            || V3_POSITION_MANAGER.isApprovedForAll(owner, caller);
    }

    /// @dev check that a call is to the ERC721 permit function
    function _checkV3PermitCall(bytes calldata inputs) internal pure {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }

        if (selector != IERC721Permit.permit.selector) {
            revert InvalidAction(selector);
        }
    }

    /// @dev check that the v3 position manager call is a safe call
    function _checkV3PositionManagerCall(bytes calldata inputs, address caller) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }

        if (!_isValidAction(selector)) {
            revert InvalidAction(selector);
        }

        uint256 tokenId;
        assembly {
            // tokenId is always the first parameter in the valid actions
            tokenId := calldataload(add(inputs.offset, 0x04))
        }
        // If any other address that is not the owner wants to call this function, it also needs to be approved (in addition to this contract)
        // This can be done in 2 ways:
        //    1. This contract is permitted for the specific token and the caller is approved for ALL of the owner's tokens
        //    2. This contract is permitted for ALL of the owner's tokens and the caller is permitted for the specific token
        if (!_isAuthorizedForToken(caller, tokenId)) {
            revert NotAuthorizedForToken(tokenId);
        }
    }

    /// @dev check that the cl position manager call is a safe call
    /// of the position-altering Actions, we only allow Actions.MINT
    /// this is because, if a user could be tricked into approving the UniversalRouter for
    /// their position, an attacker could take their fees, or drain their entire position
    function _checkInfiClPositionManagerCall(bytes calldata inputs) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }
        if (selector != INFI_CL_POSITION_MANAGER.modifyLiquidities.selector) {
            revert InvalidAction(selector);
        }

        // slice is `abi.encode(bytes unlockData, uint256 deadline)`
        bytes calldata slice = inputs[4:];
        // the first bytes(0) extracts the unlockData parameter from modifyLiquidities
        // unlockData = `abi.encode(bytes actions, bytes[] params)`
        // the second bytes(0) extracts the actions parameter from unlockData
        bytes calldata actions = slice.toBytes(0).toBytes(0);

        uint256 numActions = actions.length;

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            if (
                action == Actions.CL_INCREASE_LIQUIDITY || action == Actions.CL_DECREASE_LIQUIDITY
                    || action == Actions.CL_BURN_POSITION
            ) {
                revert OnlyMintAllowed();
            }
        }
    }

    /// @dev check that the bin position manager call is a safe call
    /// of the position-altering Actions, we only allow Actions.BIN_ADD_LIQUIDITY
    /// this is because, if a user could be tricked into approving the UniversalRouter for
    /// their position, an attacker could drain their entire position
    function _checkInfiBinPositionManagerCall(bytes calldata inputs) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }
        if (selector != INFI_BIN_POSITION_MANAGER.modifyLiquidities.selector) {
            revert InvalidAction(selector);
        }

        // slice is `abi.encode(bytes unlockData, uint256 deadline)`
        bytes calldata slice = inputs[4:];
        // the first bytes(0) extracts the unlockData parameter from modifyLiquidities
        // unlockData = `abi.encode(bytes actions, bytes[] params)`
        // the second bytes(0) extracts the actions parameter from unlockData
        bytes calldata actions = slice.toBytes(0).toBytes(0);

        uint256 numActions = actions.length;

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);
            if (action == Actions.BIN_REMOVE_LIQUIDITY) {
                revert OnlyAddLiqudityAllowed();
            }
        }
    }
}
