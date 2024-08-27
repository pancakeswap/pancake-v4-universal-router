// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {SafeCastTemp} from "../../../src/libraries/SafeCast.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Tick} from "pancake-v4-core/src/pool-cl/libraries/Tick.sol";

import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {PositionConfig} from "../../../src/pool-cl/libraries/PositionConfig.sol";

library FeeMath {
    using SafeCastTemp for uint256;
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolKey;

    /// @notice Calculates the fees accrued to a position. Used for testing purposes.
    function getFeesOwed(ICLPositionManager posm, ICLPoolManager manager, PositionConfig memory config, uint256 tokenId)
        internal
        view
        returns (BalanceDelta feesOwed)
    {
        PoolId poolId = config.poolKey.toId();

        // getPositionInfo(poolId, owner, tL, tU, salt)
        // owner is the position manager
        // salt is the tokenId
        CLPosition.Info memory info =
            manager.getPosition(poolId, address(posm), config.tickLower, config.tickUpper, bytes32(tokenId));

        uint128 liquidity = info.liquidity;
        uint256 feeGrowthInside0LastX128 = info.feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128 = info.feeGrowthInside1LastX128;

        (uint256 feeGrowthInside0X218, uint256 feeGrowthInside1X128) =
            _getFeeGrowthInside(manager, poolId, config.tickLower, config.tickUpper);

        feesOwed = getFeesOwed(
            feeGrowthInside0X218, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );
    }

    function getFeesOwed(
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint256 liquidity
    ) internal pure returns (BalanceDelta feesOwed) {
        uint128 token0Owed = getFeeOwed(feeGrowthInside0X128, feeGrowthInside0LastX128, liquidity);
        uint128 token1Owed = getFeeOwed(feeGrowthInside1X128, feeGrowthInside1LastX128, liquidity);
        feesOwed = toBalanceDelta(uint256(token0Owed).toInt128(), uint256(token1Owed).toInt128());
    }

    function getFeeOwed(uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128, uint256 liquidity)
        internal
        pure
        returns (uint128 tokenOwed)
    {
        tokenOwed =
            (FullMath.mulDiv(feeGrowthInsideX128 - feeGrowthInsideLastX128, liquidity, FixedPoint128.Q128)).toUint128();
    }

    // TODO: should we consider migrating this into core repo ?
    function _getFeeGrowthInside(ICLPoolManager manager, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = manager.getFeeGrowthGlobals(poolId);

        Tick.Info memory lowerTickInfo = manager.getPoolTickInfo(poolId, tickLower);
        Tick.Info memory upperTickInfo = manager.getPoolTickInfo(poolId, tickUpper);
        uint256 lowerFeeGrowthOutside0X128 = lowerTickInfo.feeGrowthOutside0X128;
        uint256 lowerFeeGrowthOutside1X128 = lowerTickInfo.feeGrowthOutside1X128;
        uint256 upperFeeGrowthOutside0X128 = upperTickInfo.feeGrowthOutside0X128;
        uint256 upperFeeGrowthOutside1X128 = upperTickInfo.feeGrowthOutside1X128;
        (, int24 tickCurrent,,) = manager.getSlot0(poolId);
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }
}
