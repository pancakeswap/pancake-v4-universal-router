// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {Fuzzers} from "pancake-v4-core/test/pool-cl/helpers/Fuzzers.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {ICLPositionManager} from "../../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../../src/libraries/Actions.sol";
import {PositionConfig} from "../../../../src/pool-cl/libraries/PositionConfig.sol";
import {Planner, Plan} from "../../../../src/libraries/Planner.sol";

contract LiquidityFuzzers is Fuzzers {
    using Planner for Plan;
    using CLPoolParametersHelper for bytes32;

    function addFuzzyLiquidity(
        ICLPositionManager lpm,
        address recipient,
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, ICLPoolManager.ModifyLiquidityParams memory) {
        params = Fuzzers.createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint128 MAX_SLIPPAGE_INCREASE = type(uint128).max;
        Plan memory planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                config,
                uint256(params.liquidityDelta),
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                recipient,
                hookData
            )
        );

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        return (tokenId, params);
    }

    /// @dev Obtain fuzzed and bounded parameters for creating two-sided liquidity
    /// @param key The pool key
    /// @param params ICLPoolManager.ModifyLiquidityParams Note that these parameters are unbounded
    /// @param sqrtPriceX96 The current sqrt price
    function createFuzzyTwoSidedLiquidityParams(
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96
    ) internal pure returns (ICLPoolManager.ModifyLiquidityParams memory result) {
        (result.tickLower, result.tickUpper) = boundTicks(key, params.tickLower, params.tickUpper);
        // alternative to the following line for the sake of failed too many times:
        // vm.assume(params.tickLower < 0 && 0 < params.tickUpper); // require two-sided liquidity
        int24 tickSpacing = key.parameters.getTickSpacing();
        result.tickLower =
            int24(bound(result.tickLower, TickMath.minUsableTick(tickSpacing), -1) * tickSpacing / tickSpacing);
        result.tickUpper =
            int24(bound(result.tickUpper, 1, TickMath.maxUsableTick(tickSpacing)) * tickSpacing / tickSpacing);
        int256 liquidityDeltaFromAmounts =
            getLiquidityDeltaFromAmounts(result.tickLower, result.tickUpper, sqrtPriceX96);
        result.liquidityDelta = boundLiquidityDelta(key, params.liquidityDelta, liquidityDeltaFromAmounts);
    }

    function addFuzzyTwoSidedLiquidity(
        ICLPositionManager lpm,
        address recipient,
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, ICLPoolManager.ModifyLiquidityParams memory) {
        params = createFuzzyTwoSidedLiquidityParams(key, params, sqrtPriceX96);
        PositionConfig memory config =
            PositionConfig({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        uint128 MAX_SLIPPAGE_INCREASE = type(uint128).max;
        Plan memory planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                config,
                uint256(params.liquidityDelta),
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                recipient,
                hookData
            )
        );

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        return (tokenId, params);
    }
}
