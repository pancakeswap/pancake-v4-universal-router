// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";

import {V4Router} from "pancake-v4-periphery/src/V4Router.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IBinRouterBase} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {DeltaResolver} from "pancake-v4-periphery/src/base/DeltaResolver.sol";
import {CLCalldataDecoder} from "pancake-v4-periphery/src/pool-cl/libraries/CLCalldataDecoder.sol";
import {BinCalldataDecoder} from "pancake-v4-periphery/src/pool-bin/libraries/BinCalldataDecoder.sol";
import {IV4Router} from "pancake-v4-periphery/src/interfaces/IV4Router.sol";
import {SafeCastTemp} from "pancake-v4-periphery/src/libraries/SafeCast.sol";
import {ImmutableState} from "pancake-v4-periphery/src/base/ImmutableState.sol";

/// @dev simple contract for internal use to perform a swap on testnet.
/// !!!!!! STRICTLY NOT for production use
contract QaSwapRouter is DeltaResolver {
    using CLCalldataDecoder for bytes;
    using BinCalldataDecoder for bytes;
    using SafeCastTemp for *;
    using SafeCast for *;

    error NotVault();

    // IVault public vault;
    ICLPoolManager public clPoolManager;
    IBinPoolManager public binPoolManager;
    IAllowanceTransfer public permit2;

    /// @notice Only allow calls from the Vault contract
    modifier onlyByVault() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    constructor(
        IVault _vault,
        ICLPoolManager _clPoolManager,
        IBinPoolManager _binPoolManager,
        IAllowanceTransfer _permit2
    ) ImmutableState(_vault) {
        clPoolManager = _clPoolManager;
        binPoolManager = _binPoolManager;
        permit2 = _permit2;
    }

    function clSwapExactInputSingle(ICLRouterBase.CLSwapExactInputSingleParams calldata params) external payable {
        vault.lock(abi.encode("clSwapExactInputSingle", abi.encode(msg.sender, params)));
    }

    function clSwapExactInputSingle(
        PoolId poolId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bytes memory hookData
    ) external payable {
        (Currency curr0, Currency curr1, IHooks hook, IPoolManager pm, uint24 fee, bytes32 param) =
            clPoolManager.poolIdToPoolKey(poolId);
        PoolKey memory poolKey = PoolKey(curr0, curr1, hook, pm, fee, param);

        ICLRouterBase.CLSwapExactInputSingleParams memory params = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            hookData: hookData
        });
        vault.lock(abi.encode("clSwapExactInputSingle", abi.encode(msg.sender, params)));
    }

    function poolKeyToPoolId(Currency curr0, Currency curr1, IHooks hook, IPoolManager pm, uint24 fee, bytes32 param)
        external
        pure
        returns (bytes32)
    {
        PoolKey memory poolKey = PoolKey(curr0, curr1, hook, pm, fee, param);
        return PoolId.unwrap(poolKey.toId());
    }

    function binSwapExactInputSingle(IBinRouterBase.BinSwapExactInputSingleParams calldata params) external payable {
        vault.lock(abi.encode("binSwapExactInputSingle", abi.encode(msg.sender, params)));
    }

    function binSwapExactInputSingle(
        PoolId poolId,
        bool swapForY,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bytes memory hookData
    ) external payable {
        (Currency curr0, Currency curr1, IHooks hook, IPoolManager pm, uint24 fee, bytes32 param) =
            binPoolManager.poolIdToPoolKey(poolId);
        PoolKey memory poolKey = PoolKey(curr0, curr1, hook, pm, fee, param);

        IBinRouterBase.BinSwapExactInputSingleParams memory params = IBinRouterBase.BinSwapExactInputSingleParams({
            poolKey: poolKey,
            swapForY: swapForY,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            hookData: hookData
        });
        vault.lock(abi.encode("binSwapExactInputSingle", abi.encode(msg.sender, params)));
    }

    function lockAcquired(bytes calldata callbackData) external onlyByVault returns (bytes memory) {
        (bytes memory action, bytes memory rawCallbackData) = abi.decode(callbackData, (bytes, bytes));

        if (keccak256(action) == keccak256("clSwapExactInputSingle")) {
            (address sender, ICLRouterBase.CLSwapExactInputSingleParams memory params) =
                abi.decode(rawCallbackData, (address, ICLRouterBase.CLSwapExactInputSingleParams));

            _clSwapExactInputSingle(sender, params);
        } else if (keccak256(action) == keccak256("binSwapExactInputSingle")) {
            (address sender, IBinRouterBase.BinSwapExactInputSingleParams memory params) =
                abi.decode(rawCallbackData, (address, IBinRouterBase.BinSwapExactInputSingleParams));

            _binSwapExactInputSingle(sender, params);
        } else {
            revert("QaSwapRouter: invalid action");
        }
    }

    /// @dev referenced from CLRouterBase.sol
    function _clSwapExactInputSingle(address sender, ICLRouterBase.CLSwapExactInputSingleParams memory params)
        internal
    {
        uint128 amountOut = _clSwapExactPrivate(
            params.poolKey, params.zeroForOne, -int256(uint256(params.amountIn)), params.hookData
        ).toUint128();
        if (amountOut < params.amountOutMinimum) {
            revert IV4Router.V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }

        (Currency inputCurrency, Currency outputCurrency) = params.zeroForOne
            ? (params.poolKey.currency0, params.poolKey.currency1)
            : (params.poolKey.currency1, params.poolKey.currency0);

        // pay and take
        _settle(inputCurrency, sender, _getFullDebt(inputCurrency));
        _take(outputCurrency, sender, _getFullCredit(outputCurrency));
    }

    /// @dev referenced from CLRouterBase.sol
    function _clSwapExactPrivate(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        private
        returns (int128 reciprocalAmount)
    {
        BalanceDelta delta = clPoolManager.swap(
            poolKey,
            ICLPoolManager.SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            ),
            hookData
        );

        reciprocalAmount = (zeroForOne == amountSpecified < 0) ? delta.amount1() : delta.amount0();
    }

    /// @dev reference from BinRouterBase.sol
    function _binSwapExactInputSingle(address sender, IBinRouterBase.BinSwapExactInputSingleParams memory params)
        internal
    {
        uint128 amountOut = _swapBinExactPrivate(
            params.poolKey, params.swapForY, -(params.amountIn.safeInt128()), params.hookData
        ).toUint128();

        if (amountOut < params.amountOutMinimum) {
            revert IV4Router.V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }

        (Currency inputCurrency, Currency outputCurrency) = params.swapForY
            ? (params.poolKey.currency0, params.poolKey.currency1)
            : (params.poolKey.currency1, params.poolKey.currency0);

        // pay and take
        _settle(inputCurrency, sender, _getFullDebt(inputCurrency));
        _take(outputCurrency, sender, _getFullCredit(outputCurrency));
    }

    /// @dev referenced from BinRouterBase.sol
    function _swapBinExactPrivate(PoolKey memory poolKey, bool swapForY, int128 amountSpecified, bytes memory hookData)
        private
        returns (int128 reciprocalAmount)
    {
        BalanceDelta delta = binPoolManager.swap(poolKey, swapForY, amountSpecified, hookData);
        reciprocalAmount = (swapForY == amountSpecified < 0) ? delta.amount1() : delta.amount0();
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override(DeltaResolver) {
        if (payer == address(this)) {
            currency.transfer(address(vault), amount);
        } else {
            permit2.transferFrom(payer, address(vault), uint160(amount), Currency.unwrap(currency));
        }
    }
}
