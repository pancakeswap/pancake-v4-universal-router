// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {SafeCastTemp} from "./libraries/SafeCast.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {CLCalldataDecoder} from "./pool-cl/libraries/CLCalldataDecoder.sol";
import {BinCalldataDecoder} from "./pool-bin/libraries/BinCalldataDecoder.sol";
import {CLRouterBase} from "./pool-cl/CLRouterBase.sol";
import {BinRouterBase} from "./pool-bin/BinRouterBase.sol";

/// @title PancakeswapV4Router
/// @notice Abstract contract that contains all internal logic needed for routing through Pancakeswap V4 pools
/// @dev the entry point to executing actions in this contract is calling `BaseActionsRouter._executeActions`
/// An inheriting contract should call _executeActions at the point that they wish actions to be executed
abstract contract V4Router is IV4Router, CLRouterBase, BinRouterBase, BaseActionsRouter {
    using BipsLibrary for uint256;
    using CalldataDecoder for bytes;
    using CLCalldataDecoder for bytes;
    using BinCalldataDecoder for bytes;

    constructor(IVault _vault, ICLPoolManager _clPoolManager, IBinPoolManager _binPoolManager)
        BaseActionsRouter(_vault)
        CLRouterBase(_clPoolManager)
        BinRouterBase(_binPoolManager)
    {}

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // swap actions and payment actions in different blocks for gas efficiency
        if (action < Actions.SETTLE) {
            if (action == Actions.CL_SWAP_EXACT_IN) {
                IV4Router.CLSwapExactInputParams calldata swapParams = params.decodeCLSwapExactInParams();
                _swapExactInput(swapParams);
            } else if (action == Actions.CL_SWAP_EXACT_IN_SINGLE) {
                IV4Router.CLSwapExactInputSingleParams calldata swapParams = params.decodeCLSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
            } else if (action == Actions.CL_SWAP_EXACT_OUT) {
                IV4Router.CLSwapExactOutputParams calldata swapParams = params.decodeCLSwapExactOutParams();
                _swapExactOutput(swapParams);
            } else if (action == Actions.CL_SWAP_EXACT_OUT_SINGLE) {
                IV4Router.CLSwapExactOutputSingleParams calldata swapParams = params.decodeCLSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
            } else {
                revert UnsupportedAction(action);
            }
        } else if (action > Actions.BURN_6909) {
            if (action == Actions.BIN_SWAP_EXACT_IN) {
                IV4Router.BinSwapExactInputParams calldata swapParams = params.decodeBinSwapExactInParams();
                _swapExactInput(swapParams);
            } else if (action == Actions.BIN_SWAP_EXACT_IN_SINGLE) {
                IV4Router.BinSwapExactInputSingleParams calldata swapParams = params.decodeBinSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
            } else if (action == Actions.BIN_SWAP_EXACT_OUT) {
                IV4Router.BinSwapExactOutputParams calldata swapParams = params.decodeBinSwapExactOutParams();
                _swapExactOutput(swapParams);
            } else if (action == Actions.BIN_SWAP_EXACT_OUT_SINGLE) {
                IV4Router.BinSwapExactOutputSingleParams calldata swapParams =
                    params.decodeBinSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
            } else {
                revert UnsupportedAction(action);
            }
        } else {
            if (action == Actions.SETTLE_TAKE_PAIR) {
                (Currency settleCurrency, Currency takeCurrency) = params.decodeCurrencyPair();
                _settle(settleCurrency, msgSender(), _getFullDebt(settleCurrency));
                _take(takeCurrency, msgSender(), _getFullCredit(takeCurrency));
            } else if (action == Actions.SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullDebt(currency);
                if (amount > maxAmount) revert V4TooMuchRequested();
                _settle(currency, msgSender(), amount);
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, uint256 minAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullCredit(currency);
                if (amount < minAmount) revert V4TooLittleReceived();
                _take(currency, msgSender(), amount);
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullCredit(currency).calculatePortion(bips));
            } else {
                revert UnsupportedAction(action);
            }
        }
    }
}
