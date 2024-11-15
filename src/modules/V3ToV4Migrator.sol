// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {RouterImmutables} from "../base/RouterImmutables.sol";
import {IV3NonfungiblePositionManager} from
    "pancake-v4-periphery/src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "pancake-v4-periphery/src/libraries/CalldataDecoder.sol";
import {IPositionManager} from "pancake-v4-periphery/src/interfaces/IPositionManager.sol";
import {console2} from "forge-std/console2.sol";

/// @title V3 to V4 Migrator
/// @notice A contract that migrates liquidity from PancakeSwap V3 to V4
abstract contract V3ToV4Migrator is RouterImmutables {
    using CalldataDecoder for bytes;

    error NotAuthorizedForToken(uint256 tokenId);
    error InvalidAction(bytes4 action);
    error OnlyMintAllowed();
    error OnlyAddLiqudityAllowed();
    error BlacklistedAction();

    enum PoolType {
        CL,
        BIN
    }

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

    function isBlacklistedCLPositionManagerAction(uint256 action) internal pure returns (bool) {
        return action == Actions.CL_INCREASE_LIQUIDITY || action == Actions.CL_DECREASE_LIQUIDITY
            || action == Actions.CL_BURN_POSITION;
    }

    function isBlacklistedBinPositionManagerAction(uint256 action) internal pure returns (bool) {
        return action == Actions.BIN_REMOVE_LIQUIDITY;
    }

    /// @dev check that the v4 position manager call is a safe call
    /// of the position-altering Actions, we only allow Actions.MINT
    /// this is because, if a user could be tricked into approving the UniversalRouter for
    /// their position, an attacker could take their fees, or drain their entire position
    function _checkV4ClPositionManagerCall(bytes calldata inputs) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }
        if (selector != V4_CL_POSITION_MANAGER.modifyLiquidities.selector) {
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

    /// @dev check that the v4 position manager call is a safe call
    /// of the position-altering Actions, we only allow Actions.BIN_ADD_LIQUIDITY
    /// this is because, if a user could be tricked into approving the UniversalRouter for
    /// their position, an attacker could drain their entire position
    function _checkV4BinPositionManagerCall(bytes calldata inputs) internal view {
        bytes4 selector;
        assembly {
            selector := calldataload(inputs.offset)
        }
        if (selector != V4_BIN_POSITION_MANAGER.modifyLiquidities.selector) {
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
