// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IPositionManager} from "../../interfaces/IPositionManager.sol";

interface IBinPositionManager is IPositionManager {
    error IdOverflows(int256);
    error IdDesiredOverflows(uint24);
    error AddLiquidityInputActiveIdMismath();
    error OutputAmountSlippage();
    error IncorrectOutputAmount();

    /// @notice BinAddLiquidityParams
    /// - amount0: Amount to send for token0
    /// - amount1: Amount to send for token1
    /// - amount0Min: Min amount to send for token0
    /// - amount1Min: Min amount to send for token1
    /// - activeIdDesired: Active id that user wants to add liquidity from
    /// - idSlippage: Number of id that are allowed to slip
    /// - deltaIds: List of delta ids to add liquidity (`deltaId = activeId - desiredId`)
    /// - distributionX: Distribution of tokenX with sum(distributionX) = 1e18 (100%) or 0 (0%)
    /// - distributionY: Distribution of tokenY with sum(distributionY) = 1e18 (100%) or 0 (0%)
    /// - to: Address of recipient
    /// - deadline: Deadline of transaction
    struct BinAddLiquidityParams {
        PoolKey poolKey;
        uint128 amount0;
        uint128 amount1;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
    }

    /// @notice BinRemoveLiquidityParams
    /// - amount0Min: Min amount to recieve for token0
    /// - amount1Min: Min amount to recieve for token1
    /// - ids: List of bin ids to remove liquidity
    /// - amounts: List of share amount to remove for each bin
    /// - from: Address of NFT holder to burn the NFT
    /// - deadline: Deadline of transaction
    struct BinRemoveLiquidityParams {
        PoolKey poolKey;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256[] ids;
        uint256[] amounts;
        address from;
    }

    function binPoolManager() external view returns (IBinPoolManager);

    /// @notice Initialize a v4 PCS bin pool
    function initializePool(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external payable;

    /// @notice Return the position information associated with a given tokenId
    /// @dev Revert if non-existent tokenId
    /// @param tokenId Id of the token that represent position
    function positions(uint256 tokenId)
        external
        view
        returns (PoolId poolId, Currency currency0, Currency currency1, uint24 fee, uint24 binId);
}
