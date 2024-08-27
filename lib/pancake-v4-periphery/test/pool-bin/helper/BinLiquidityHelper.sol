// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PriceHelper} from "pancake-v4-core/src/pool-bin/libraries/PriceHelper.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";

import {Actions} from "../../../src/libraries/Actions.sol";
import {IBinPositionManager} from "../../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "../../../src/pool-bin/BinPositionManager.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";

contract BinLiquidityHelper is Test {
    using Planner for Plan;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    /// @dev helper method to approve token0/token1 of poolKey to binPositionManager
    function approveBinPm(address from, PoolKey memory key, address binPm, IAllowanceTransfer permit2) internal {
        approveBinPmForCurrency(from, key.currency0, binPm, permit2);
        approveBinPmForCurrency(from, key.currency1, binPm, permit2);
    }

    /// @dev helper method to approve token to binPositionManager
    function approveBinPmForCurrency(address from, Currency currency, address binPm, IAllowanceTransfer permit2)
        internal
    {
        vm.startPrank(from);

        // Because BinPm uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);

        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        permit2.approve(Currency.unwrap(currency), binPm, type(uint160).max, type(uint48).max);

        vm.stopPrank();
    }

    /// @dev helper method to compute tokenId minted, similar to BinTokenLibrary logic
    function calculateTokenId(PoolId poolId, uint256 binId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, binId)));
    }

    /// @dev helper method to calculate expected liquidity minted
    function calculateLiquidityMinted(
        bytes32 binReserves,
        uint128 amt0,
        uint128 amt1,
        uint24 binId,
        uint16 binStep,
        uint256 binTotalSupply
    ) internal pure returns (uint256 share) {
        bytes32 amountIn = PackedUint128Math.encode(amt0, amt1);
        uint256 binPrice = PriceHelper.getPriceFromId(binId, binStep);

        (share,) = BinHelper.getSharesAndEffectiveAmountsIn(binReserves, amountIn, binPrice, binTotalSupply);
    }

    /// @dev add liquidity to activeBin with 1 ether
    function _addLiquidity(BinPositionManager binPm, PoolKey memory key, uint24[] memory binIds, uint24 activeId)
        public
        returns (uint256[] memory tokenIds, uint256[] memory liquidityMinted)
    {
        (tokenIds, liquidityMinted) = _addLiquidity(binPm, key, binIds, activeId, address(this));
    }

    /// @dev similar to the above method, but mint to a different recipient
    function _addLiquidity(
        BinPositionManager binPm,
        PoolKey memory key,
        uint24[] memory binIds,
        uint24 activeId,
        address recipient
    ) public returns (uint256[] memory tokenIds, uint256[] memory liquidityMinted) {
        tokenIds = new uint256[](binIds.length);
        liquidityMinted = new uint256[](binIds.length);

        // get liquidity before
        for (uint256 i; i < binIds.length; i++) {
            tokenIds[i] = calculateTokenId(key.toId(), binIds[i]);
            liquidityMinted[i] = binPm.balanceOf(recipient, tokenIds[i]);
        }

        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key, binIds, 1 ether, 1 ether, activeId, recipient);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key);
        binPm.modifyLiquidities(payload, block.timestamp + 1);

        // calculate liquidity now as the diff
        for (uint256 i; i < binIds.length; i++) {
            liquidityMinted[i] = binPm.balanceOf(recipient, tokenIds[i]) - liquidityMinted[i];
        }
    }

    /// @dev helper method to construct add liquidity param
    /// @param key pool key
    /// @param binIds list of binIds
    /// @param amountX amount of token0
    /// @param amountY amount of token1
    /// @param activeId current activeId
    /// @param recipient address to receive the liquidity
    function _getAddParams(
        PoolKey memory key,
        uint24[] memory binIds,
        uint128 amountX,
        uint128 amountY,
        uint24 activeId,
        address recipient
    ) internal pure returns (IBinPositionManager.BinAddLiquidityParams memory params) {
        uint256 totalBins = binIds.length;

        uint8 nbBinX; // num of bins to the right
        uint8 nbBinY; // num of bins to the left
        for (uint256 i; i < totalBins; ++i) {
            if (binIds[i] >= activeId) nbBinX++;
            if (binIds[i] <= activeId) nbBinY++;
        }

        uint256[] memory distribX = new uint256[](totalBins);
        uint256[] memory distribY = new uint256[](totalBins);
        for (uint256 i; i < totalBins; ++i) {
            uint24 binId = binIds[i];
            distribX[i] = binId >= activeId ? uint256(1e18 / nbBinX).safe64() : 0;
            distribY[i] = binId <= activeId ? uint256(1e18 / nbBinY).safe64() : 0;
        }

        params = IBinPositionManager.BinAddLiquidityParams({
            poolKey: key,
            amount0: amountX,
            amount1: amountY,
            amount0Min: 0,
            amount1Min: 0,
            activeIdDesired: uint256(activeId),
            idSlippage: 0,
            deltaIds: convertToRelative(binIds, activeId),
            distributionX: distribX,
            distributionY: distribY,
            to: recipient
        });
    }

    function _getRemoveParams(PoolKey memory key, uint24[] memory binIds, uint256[] memory amounts, address from)
        internal
        pure
        returns (IBinPositionManager.BinRemoveLiquidityParams memory params)
    {
        uint256[] memory ids = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            ids[i] = uint256(binIds[i]);
        }

        params = IBinPositionManager.BinRemoveLiquidityParams({
            poolKey: key,
            amount0Min: 0,
            amount1Min: 0,
            ids: ids,
            amounts: amounts,
            from: from
        });
    }

    /// @dev Generate list of binIds. eg. if activeId = 100, numBins = 3, it will return [99, 100, 101]
    ///      However, if numBins is even number, it will generate 1 more bin to the left, eg.
    ///      if activeId = 100, numBins = 4, return [98, 99, 100, 101]
    function getBinIds(uint24 activeId, uint8 numBins) internal pure returns (uint24[] memory binIds) {
        binIds = new uint24[](numBins);

        uint24 startId = activeId - (numBins / 2);
        for (uint256 i; i < numBins; i++) {
            binIds[i] = startId;
            startId++;
        }
    }

    /// @dev Given list of binIds and activeIds, return the delta ids.
    //       eg. given id: [100, 101, 102] and activeId: 101, return [-1, 0, 1]
    function convertToRelative(uint24[] memory absoluteIds, uint24 activeId)
        internal
        pure
        returns (int256[] memory relativeIds)
    {
        relativeIds = new int256[](absoluteIds.length);
        for (uint256 i = 0; i < absoluteIds.length; i++) {
            relativeIds[i] = int256(uint256(absoluteIds[i])) - int256(uint256(activeId));
        }
    }
}
