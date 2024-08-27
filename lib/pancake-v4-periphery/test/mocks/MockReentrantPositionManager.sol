// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IBinMigrator, IBaseMigrator} from "../../src/pool-bin/interfaces/IBinMigrator.sol";
import {ICLMigrator} from "../../src/pool-cl/interfaces/ICLMigrator.sol";

/// @title MockReentrantPositionManager
/// @notice This contract is used to test reentrancy in PositionManager
/// @dev Can add more reentrant types if needed
contract MockReentrantPositionManager is Test {
    IBinMigrator public binMigrator;
    ICLMigrator public clMigrator;
    IAllowanceTransfer public immutable permit2;

    // CLMigrator need to query this in constructor
    ICLPoolManager public clPoolManager;

    enum ReentrantType {
        BinMigrateFromV3,
        BinMigrateFromV2,
        CLMigrateFromV3,
        CLMigrateFromV2
    }

    ReentrantType public reentrantType;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    // need to set the binMigrator after binMigrator is deployed
    function setBinMigrator(IBinMigrator _migrator) external {
        binMigrator = _migrator;
    }

    // need to set clMigrator after clMigrator is deployed
    function setCLMigrator(ICLMigrator _migrator) external {
        clMigrator = _migrator;
    }

    // need to set clPoolManager after MockReentrantPositionManager is deployed
    function setCLPoolMnager(ICLPoolManager _clPoolManager) external {
        clPoolManager = _clPoolManager;
    }

    function setRenentrantType(ReentrantType _type) external {
        reentrantType = _type;
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {
        IBinMigrator.V4BinPoolParams memory v4BinPoolParams = _generateMockV4BinPoolParams();

        ICLMigrator.V4CLPoolParams memory v4CLPoolParams = _generateMockV4CLPoolParams();

        IBaseMigrator.V3PoolParams memory v3PoolParams = _generateMockV3PoolParams();

        IBaseMigrator.V2PoolParams memory v2PoolParams = _generateMockV2PoolParams();
        // Mock data can fulfill the requirement because it will trigger ContractLocked revert before any operations are executed
        if (reentrantType == ReentrantType.BinMigrateFromV2) {
            binMigrator.migrateFromV2(v2PoolParams, v4BinPoolParams, 0, 0);
        } else if (reentrantType == ReentrantType.BinMigrateFromV3) {
            binMigrator.migrateFromV3(v3PoolParams, v4BinPoolParams, 0, 0);
        } else if (reentrantType == ReentrantType.CLMigrateFromV2) {
            clMigrator.migrateFromV2(v2PoolParams, v4CLPoolParams, 0, 0);
        } else if (reentrantType == ReentrantType.CLMigrateFromV3) {
            clMigrator.migrateFromV3(v3PoolParams, v4CLPoolParams, 0, 0);
        }
    }

    function _generateMockPoolKey() internal returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(makeAddr("currency0")),
            currency1: Currency.wrap(makeAddr("currency1")),
            hooks: IHooks(makeAddr("hook")),
            poolManager: IPoolManager(makeAddr("pm")),
            fee: 100,
            parameters: hex"1022"
        });
    }

    function _generateMockV4BinPoolParams() internal returns (IBinMigrator.V4BinPoolParams memory) {
        return IBinMigrator.V4BinPoolParams({
            poolKey: _generateMockPoolKey(),
            amount0Min: 0,
            amount1Min: 0,
            activeIdDesired: 0,
            idSlippage: 0,
            deltaIds: new int256[](0),
            distributionX: new uint256[](0),
            distributionY: new uint256[](0),
            to: address(0),
            deadline: 0
        });
    }

    function _generateMockV4CLPoolParams() internal returns (ICLMigrator.V4CLPoolParams memory) {
        return ICLMigrator.V4CLPoolParams({
            poolKey: _generateMockPoolKey(),
            tickLower: 0,
            tickUpper: 0,
            liquidityMin: 0,
            recipient: address(0),
            deadline: 0
        });
    }

    function _generateMockV3PoolParams() internal pure returns (IBaseMigrator.V3PoolParams memory) {
        return IBaseMigrator.V3PoolParams({
            nfp: address(0),
            tokenId: 0,
            liquidity: 0,
            amount0Min: 0,
            amount1Min: 0,
            collectFee: false,
            deadline: 0
        });
    }

    function _generateMockV2PoolParams() internal pure returns (IBaseMigrator.V2PoolParams memory) {
        return IBaseMigrator.V2PoolParams({pair: address(0), migrateAmount: 0, amount0Min: 0, amount1Min: 0});
    }
}
