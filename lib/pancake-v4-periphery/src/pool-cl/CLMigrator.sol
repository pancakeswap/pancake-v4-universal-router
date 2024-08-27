// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "pancake-v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {BaseMigrator, IV3NonfungiblePositionManager} from "../base/BaseMigrator.sol";
import {ICLMigrator, PoolKey} from "./interfaces/ICLMigrator.sol";
import {PositionConfig} from "./libraries/PositionConfig.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {ICLPositionManager} from "./interfaces/ICLPositionManager.sol";
import {Actions} from "../libraries/Actions.sol";
import {Plan, Planner} from "../libraries/Planner.sol";
import {ReentrancyLock} from "../base/ReentrancyLock.sol";

contract CLMigrator is ICLMigrator, BaseMigrator, ReentrancyLock {
    using PoolIdLibrary for PoolKey;
    using Planner for Plan;

    ICLPositionManager public immutable clPositionManager;
    ICLPoolManager public immutable clPoolManager;

    constructor(address _WETH9, address _clPositionManager, IAllowanceTransfer _permit2)
        BaseMigrator(_WETH9, _clPositionManager, _permit2)
    {
        clPositionManager = ICLPositionManager(_clPositionManager);
        clPoolManager = clPositionManager.clPoolManager();
    }

    /// @inheritdoc ICLMigrator
    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        V4CLPoolParams calldata v4PoolParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override isNotLocked {
        bool shouldReversePair = checkTokensOrderAndMatchFromV2(
            v2PoolParams.pair, v4PoolParams.poolKey.currency0, v4PoolParams.poolKey.currency1
        );

        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV2(v2PoolParams, shouldReversePair);

        /// @notice if user mannually specify the price range, they might need to send extra token
        batchAndNormalizeTokens(
            v4PoolParams.poolKey.currency0, v4PoolParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0In = amount0Received + extraAmount0;
        uint256 amount1In = amount1Received + extraAmount1;
        MintParams memory mintParams = MintParams({
            poolKey: v4PoolParams.poolKey,
            tickLower: v4PoolParams.tickLower,
            tickUpper: v4PoolParams.tickUpper,
            amount0In: uint128(amount0In),
            amount1In: uint128(amount1In),
            liquidityMin: v4PoolParams.liquidityMin,
            recipient: v4PoolParams.recipient
        });
        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(mintParams, v4PoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0In > amount0Consumed) {
                v4PoolParams.poolKey.currency0.transfer(v4PoolParams.recipient, amount0In - amount0Consumed);
            }
            if (amount1In > amount1Consumed) {
                v4PoolParams.poolKey.currency1.transfer(v4PoolParams.recipient, amount1In - amount1Consumed);
            }
        }
    }

    /// @inheritdoc ICLMigrator
    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        V4CLPoolParams calldata v4PoolParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override isNotLocked {
        bool shouldReversePair = checkTokensOrderAndMatchFromV3(
            v3PoolParams.nfp, v3PoolParams.tokenId, v4PoolParams.poolKey.currency0, v4PoolParams.poolKey.currency1
        );
        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV3(v3PoolParams, shouldReversePair);

        /// @notice if user mannually specify the price range, they need to send extra token
        batchAndNormalizeTokens(
            v4PoolParams.poolKey.currency0, v4PoolParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0In = amount0Received + extraAmount0;
        uint256 amount1In = amount1Received + extraAmount1;
        MintParams memory mintParams = MintParams({
            poolKey: v4PoolParams.poolKey,
            tickLower: v4PoolParams.tickLower,
            tickUpper: v4PoolParams.tickUpper,
            amount0In: uint128(amount0In),
            amount1In: uint128(amount1In),
            liquidityMin: v4PoolParams.liquidityMin,
            recipient: v4PoolParams.recipient
        });
        (uint256 amount0Consumed, uint256 amount1Consumed) =
            _addLiquidityToTargetPool(mintParams, v4PoolParams.deadline);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0In > amount0Consumed) {
                v4PoolParams.poolKey.currency0.transfer(v4PoolParams.recipient, amount0In - amount0Consumed);
            }
            if (amount1In > amount1Consumed) {
                v4PoolParams.poolKey.currency1.transfer(v4PoolParams.recipient, amount1In - amount1Consumed);
            }
        }
    }

    /// @dev adding liquidity to target cl pool, collect surplus ETH if necessary
    /// @param params cl position manager add liquidity params
    /// @param deadline the deadline for the transaction
    /// @return amount0Consumed the actual amount of token0 consumed
    /// @return amount1Consumed the actual amount of token1 consumed
    function _addLiquidityToTargetPool(MintParams memory params, uint256 deadline)
        internal
        returns (uint256 amount0Consumed, uint256 amount1Consumed)
    {
        /// @dev currency1 cant be NATIVE
        bool nativePair = params.poolKey.currency0.isNative();
        if (!nativePair) {
            permit2ApproveMaxIfNeeded(params.poolKey.currency0, address(clPositionManager), params.amount0In);
        }
        permit2ApproveMaxIfNeeded(params.poolKey.currency1, address(clPositionManager), params.amount1In);

        (uint160 sqrtPriceX96, int24 activeTick,,) = clPoolManager.getSlot0(params.poolKey.toId());
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0In, params.amount1In
        );

        if (liquidity < params.liquidityMin) {
            revert INSUFFICIENT_LIQUIDITY();
        }

        // Calculate amt0/amt1 from liquidity, similar to CLPool modifyLiquidity logic
        if (activeTick < params.tickLower) {
            amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
        } else if (activeTick < params.tickUpper) {
            amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, true);
            amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
        } else {
            amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
        }

        PositionConfig memory config =
            PositionConfig({poolKey: params.poolKey, tickLower: params.tickLower, tickUpper: params.tickUpper});

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(config, uint256(liquidity), params.amount0In, params.amount1In, params.recipient, new bytes(0))
        );
        bytes memory lockData = planner.finalizeModifyLiquidityWithSettlePair(params.poolKey);

        clPositionManager.modifyLiquidities{value: nativePair ? amount0Consumed : 0}(lockData, deadline);
    }

    /// @inheritdoc ICLMigrator
    /// @notice Planned to be batched with migration operations through multicall to save gas
    function initializePool(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        override
        returns (int24 tick)
    {
        return clPositionManager.initializePool(poolKey, sqrtPriceX96, hookData);
    }

    receive() external payable {
        if (msg.sender != address(clPositionManager) && msg.sender != WETH9) {
            revert INVALID_ETHER_SENDER();
        }
    }
}
