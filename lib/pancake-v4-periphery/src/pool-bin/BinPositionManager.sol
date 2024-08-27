// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.20;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPool} from "pancake-v4-core/src/pool-bin/libraries/BinPool.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {LiquidityConfigurations} from "pancake-v4-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {BaseActionsRouter} from "../base/BaseActionsRouter.sol";
import {ReentrancyLock} from "../base/ReentrancyLock.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {Permit2Forwarder} from "../base/Permit2Forwarder.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IBinPositionManager} from "./interfaces/IBinPositionManager.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {Actions} from "../libraries/Actions.sol";
import {BinCalldataDecoder} from "./libraries/BinCalldataDecoder.sol";
import {BinFungibleToken} from "./BinFungibleToken.sol";
import {BinTokenLibrary} from "./libraries/BinTokenLibrary.sol";
import {Multicall_v4} from "../base/Multicall_v4.sol";

/// @title BinPositionManager
/// @notice Contract for modifying liquidity for PCS v4 Bin pools
contract BinPositionManager is
    IBinPositionManager,
    BinFungibleToken,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    Permit2Forwarder,
    Multicall_v4
{
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using CalldataDecoder for bytes;
    using PackedUint128Math for uint128;
    using BinCalldataDecoder for bytes;
    using BinTokenLibrary for PoolId;
    using BinPoolParametersHelper for bytes32;

    bytes constant ZERO_BYTES = new bytes(0);
    IBinPoolManager public immutable override binPoolManager;

    struct TokenPosition {
        PoolId poolId;
        uint24 binId;
    }

    /// @dev tokenId => TokenPosition
    mapping(uint256 => TokenPosition) private _positions;

    /// @dev poolId => poolKey
    mapping(bytes32 => PoolKey) private _poolIdToPoolKey;

    constructor(IVault _vault, IBinPoolManager _binPoolManager, IAllowanceTransfer _permit2)
        BaseActionsRouter(_vault)
        Permit2Forwarder(_permit2)
    {
        binPoolManager = _binPoolManager;
    }

    /// @dev <wip> might be refactored to BasePositionManager later
    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId)
    {
        TokenPosition memory position = _positions[tokenId];

        if (PoolId.unwrap(position.poolId) == 0) revert InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[PoolId.unwrap(position.poolId)];

        return (position.poolId, poolKey.currency0, poolKey.currency1, poolKey.fee, position.binId);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquidities(bytes calldata payload, uint256 deadline)
        external
        payable
        override
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(payload);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquiditiesWithoutLock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        override
        isNotLocked
    {
        _executeActionsWithoutLock(actions, params);
    }

    /// @inheritdoc IBinPositionManager
    function initializePool(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external payable {
        binPoolManager.initialize(poolKey, activeId, hookData);
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action > Actions.BURN_6909) {
            if (action == Actions.BIN_ADD_LIQUIDITY) {
                IBinPositionManager.BinAddLiquidityParams calldata liquidityParams =
                    params.decodeBinAddLiquidityParams();
                _addLiquidity(liquidityParams);
            } else if (action == Actions.BIN_REMOVE_LIQUIDITY) {
                IBinPositionManager.BinRemoveLiquidityParams calldata liquidityParams =
                    params.decodeBinRemoveLiquidityParams();
                _removeLiquidity(liquidityParams);
            } else {
                revert UnsupportedAction(action);
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                _settlePair(currency0, currency1);
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address to) = params.decodeCurrencyPairAndAddress();
                _takePair(currency0, currency1, to);
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = params.decodeCurrency();
                _close(currency);
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                _clearOrTake(currency, amountMax);
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
            } else {
                revert UnsupportedAction(action);
            }
        }
    }

    /// @dev Store poolKey in mapping for lookup
    function cachePoolKey(PoolKey memory poolKey) internal returns (PoolId poolId) {
        poolId = poolKey.toId();

        if (_poolIdToPoolKey[PoolId.unwrap(poolId)].parameters.getBinStep() == 0) {
            _poolIdToPoolKey[PoolId.unwrap(poolId)] = poolKey;
        }
    }

    function _addLiquidity(IBinPositionManager.BinAddLiquidityParams calldata params) internal {
        if (params.deltaIds.length != params.distributionX.length) revert InputLengthMismatch();
        if (params.deltaIds.length != params.distributionY.length) revert InputLengthMismatch();
        if (params.activeIdDesired > type(uint24).max || params.idSlippage > type(uint24).max) {
            revert AddLiquidityInputActiveIdMismath();
        }

        /// @dev Checks if the activeId is within slippage before calling mint. If user mint to activeId and there
        //       was a swap in hook.beforeMint() which changes the activeId, user txn will fail
        (uint24 activeId,,) = binPoolManager.getSlot0(params.poolKey.toId());
        if (params.activeIdDesired + params.idSlippage < activeId) revert IdDesiredOverflows(activeId);
        if (params.activeIdDesired - params.idSlippage > activeId) revert IdDesiredOverflows(activeId);

        bytes32[] memory liquidityConfigs = new bytes32[](params.deltaIds.length);
        for (uint256 i; i < liquidityConfigs.length; i++) {
            int256 _id = int256(uint256(activeId)) + params.deltaIds[i];
            if (_id < 0 || uint256(_id) > type(uint24).max) revert IdOverflows(_id);

            liquidityConfigs[i] = LiquidityConfigurations.encodeParams(
                uint64(params.distributionX[i]), uint64(params.distributionY[i]), uint24(uint256(_id))
            );
        }

        bytes32 amountIn = params.amount0.encode(params.amount1);
        (BalanceDelta delta, BinPool.MintArrays memory mintArray) = binPoolManager.mint(
            params.poolKey,
            IBinPoolManager.MintParams({liquidityConfigs: liquidityConfigs, amountIn: amountIn, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // delta amt0/amt1 will always be negative in mint case
        if (delta.amount0() > 0 || delta.amount1() > 0) revert IncorrectOutputAmount();
        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert OutputAmountSlippage();
        }

        // mint
        PoolId poolId = cachePoolKey(params.poolKey);
        uint256[] memory tokenIds = new uint256[](mintArray.ids.length);
        for (uint256 i; i < mintArray.ids.length; i++) {
            uint256 tokenId = poolId.toTokenId(mintArray.ids[i]);
            _mint(params.to, tokenId, mintArray.liquidityMinted[i]);

            if (_positions[tokenId].binId == 0) {
                _positions[tokenId] = TokenPosition({poolId: poolId, binId: uint24(mintArray.ids[i])});
            }

            tokenIds[i] = tokenId;
        }

        emit TransferBatch(msgSender(), address(0), params.to, tokenIds, mintArray.liquidityMinted);
    }

    function _removeLiquidity(IBinPositionManager.BinRemoveLiquidityParams calldata params)
        internal
        checkApproval(params.from, msgSender())
    {
        if (params.ids.length != params.amounts.length) revert InputLengthMismatch();

        BalanceDelta delta = binPoolManager.burn(
            params.poolKey,
            IBinPoolManager.BurnParams({ids: params.ids, amountsToBurn: params.amounts, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // delta amt0/amt1 will either be 0 or positive in removing liquidity
        if (delta.amount0() < 0 || delta.amount1() < 0) revert IncorrectOutputAmount();
        if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
            revert OutputAmountSlippage();
        }

        PoolId poolId = params.poolKey.toId();
        uint256[] memory tokenIds = new uint256[](params.ids.length);
        for (uint256 i; i < params.ids.length; i++) {
            uint256 tokenId = poolId.toTokenId(params.ids[i]);
            _burn(params.from, tokenId, params.amounts[i]);

            tokenIds[i] = tokenId;
        }

        emit TransferBatch(msgSender(), params.from, address(0), tokenIds, params.amounts);
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // the locker is the payer when settling
        address caller = msgSender();
        _settle(currency0, caller, _getFullDebt(currency0));
        _settle(currency1, caller, _getFullDebt(currency1));
    }

    function _takePair(Currency currency0, Currency currency1, address to) internal {
        address recipient = _mapRecipient(to);
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
    }

    function _close(Currency currency) internal {
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = vault.currencyDelta(address(this), currency);

        // the locker is the payer or receiver
        address caller = msgSender();
        if (currencyDelta < 0) {
            _settle(currency, caller, uint256(-currencyDelta));
        } else if (currencyDelta > 0) {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev integrators may elect to forfeit positive deltas with clear
    /// if the forfeit amount exceeds the user-specified max, the amount is taken instead
    function _clearOrTake(Currency currency, uint256 amountMax) internal {
        uint256 delta = _getFullCredit(currency);

        // forfeit the delta if its less than or equal to the user-specified limit
        if (delta <= amountMax) {
            vault.clear(currency, delta);
        } else {
            _take(currency, msgSender(), delta);
        }
    }

    /// @notice Sweeps the entire contract balance of specified currency to the recipient
    function _sweep(Currency currency, address to) internal {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override(DeltaResolver) {
        if (payer == address(this)) {
            // TODO: currency is guaranteed to not be eth so the native check in transfer is not optimal.
            currency.transfer(address(vault), amount);
        } else {
            permit2.transferFrom(payer, address(vault), uint160(amount), Currency.unwrap(currency));
        }
    }
}
