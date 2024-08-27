// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";

import {BinHookSavesDelta} from "./BinHookSavesDelta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IBinPositionManager} from "../../../src/pool-bin/interfaces/IBinPositionManager.sol";

/// @notice This contract is NOT a production use contract. It is meant to be used in testing to verify that external contracts can modify liquidity without a lock (IPositionManager.modifyLiquiditiesWithoutUnlock)
/// @dev a hook that can modify liquidity in beforeSwap
contract BinHookModifyLiquidities is BinHookSavesDelta {
    IBinPositionManager posm;
    IAllowanceTransfer permit2;

    function setAddresses(IBinPositionManager _posm, IAllowanceTransfer _permit2) external {
        posm = _posm;
        permit2 = _permit2;
    }

    function beforeSwap(
        address, /* sender **/
        PoolKey calldata key, /* key **/
        bool, /* swapForY **/
        int128, /* amountSpecified **/
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        approvePosmCurrency(key.currency0);
        approvePosmCurrency(key.currency1);

        (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
        posm.modifyLiquiditiesWithoutLock(actions, params);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeMint(
        address, /* sender **/
        PoolKey calldata, /* key **/
        IBinPoolManager.MintParams calldata, /* params **/
        bytes calldata hookData
    ) external override returns (bytes4, uint24) {
        if (hookData.length > 0) {
            (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutLock(actions, params);
        }
        return (this.beforeMint.selector, 0);
    }

    function beforeBurn(
        address, /* sender **/
        PoolKey calldata, /* key **/
        IBinPoolManager.BurnParams calldata, /* params **/
        bytes calldata hookData
    ) external override returns (bytes4) {
        if (hookData.length > 0) {
            (bytes memory actions, bytes[] memory params) = abi.decode(hookData, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutLock(actions, params);
        }
        return this.beforeBurn.selector;
    }

    function approvePosmCurrency(Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }
}
